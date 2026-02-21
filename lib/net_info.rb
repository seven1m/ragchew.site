require 'time'

require_relative './fetcher'
require_relative './tables'
require_relative './user_presenter'

class NetInfo
  EARTH_RADIUS_IN_KM = 6378.137
  CENTER_PERCENTILE = 75
  MIN_LATITUDES_FOR_MAJORITY = 3
  MIN_LONGITUDES_FOR_MAJORITY = 3
  MIN_CENTER_RADIUS_IN_METERS = 50000
  MAX_CENTER_RADIUS_TO_SHOW = 3000000
  LOCK_TIMEOUT = 2

  class NotFoundError < StandardError; end
  class ServerError < StandardError; end

  def initialize(name: nil, id: nil)
    if id
      @record = Tables::Net.find_by!(id:)
    elsif name
      @record = Tables::Net.find_by!(name:)
    else
      raise 'must supply either id or name to NetInfo.new'
    end
  rescue ActiveRecord::RecordNotFound
    raise NotFoundError, 'Net is closed'
  end

  def net = @record
  def name = @record.name
  def host = @record.host

  def update!(force_full: false)
    return unless cache_needs_updating?

    with_lock do
      if cache_needs_updating?
        update_cache(force_full:)
      end
    end
  end

  def update_net_right_now_with_wreckless_disregard_for_the_last_update!(force_full: false)
    with_lock do
      update_cache(force_full:)
    end
  end

  def monitor!(user:)
    if user.monitoring_net && user.monitoring_net != @record
      # already monitoring one, so stop that first
      begin
        NetInfo.new(id: user.monitoring_net_id).stop_monitoring!(user:)
      rescue NetInfo::NotFoundError
        # no biggie I guess
      end
    end

    # 2023-05-09 17:40:45 GET http://www.netlogger.org/cgi-bin/NetLogger/SubscribeToNet.php?ProtocolVersion=2.3&NetName=Daily%20Check%20in%20Net&Callsign=KI5ZDF-TIM%20MORGAN%20-%20v3.1.7L&IMSerial=0&LastExtDataSerial=0
    #                        ← 200 OK text/html 2.15k 150ms
    #                             Request                                                          Response                                                          Detail
    #Host:          www.netlogger.org
    #Accept:        www/source, text/html, video/mpeg, image/jpeg, image/x-tiff, image/x-rgb, image/x-xbm, image/gif, */*, application/postscript
    #Content-Type:  application/x-www-form-urlencoded
    #Query                                                                                                                                                                                      [m:auto]
    #ProtocolVersion:   2.3
    #NetName:           Daily Check in Net
    #Callsign:          KI5ZDF-TIM MORGAN - v3.1.7L
    #IMSerial:          0
    #LastExtDataSerial: 0

    fetcher = Fetcher.new(@record.host)
    begin
      fetcher.get(
        'SubscribeToNet.php',
        'ProtocolVersion' => '2.3',
        'NetName' => @record.name,
        'Callsign' => name_for_monitoring(user),
        'IMSerial' => '0',
        'LastExtDataSerial' => '0',
      )
      user.update!(
        monitoring_net: @record,
        monitoring_net_last_refreshed_at: Time.now,
      )
    rescue Fetcher::NotFoundError
      raise NotFoundError, 'Net gone'
    end
  end

  def stop_monitoring!(user:)
    # 2023-05-09 17:41:58 GET http://www.netlogger.org/cgi-bin/NetLogger/UnsubscribeFromNet.php?&Callsign=KI5ZDF-TIM%20MORGAN%20-%20v3.1.7L&NetName=Daily%20Check%20in%20Net
    #                        ← 200 OK text/html 176b 143ms
    #                             Request                                                          Response                                                          Detail
    #Host:          www.netlogger.org
    #Accept:        www/source, text/html, video/mpeg, image/jpeg, image/x-tiff, image/x-rgb, image/x-xbm, image/gif, */*, application/postscript
    #Content-Type:  application/x-www-form-urlencoded
    #Query                                                                                                                                                                                      [m:auto]
    #Callsign: KI5ZDF-TIM MORGAN - v3.1.7L
    #NetName:  Daily Check in Net

    fetcher = Fetcher.new(@record.host)
    begin
      fetcher.get(
        'UnsubscribeFromNet.php',
        'Callsign' => name_for_monitoring(user),
        'NetName' => @record.name,
      )
    rescue Fetcher::NotFoundError
      raise NotFoundError, 'Net gone'
    ensure
      user.update!(
        monitoring_net: nil,
        monitoring_net_last_refreshed_at: nil,
      )
    end
  end

  def send_message!(user:, message:)
    # 2023-05-09 17:24:31 POST http://www.netlogger.org/cgi-bin/NetLogger/SendInstantMessage.php
    #                         ← 200 OK text/html 176b 206ms
    #                             Request                                                          Response                                                          Detail
    #Host:            www.netlogger.org
    #Accept:          www/source, text/html, video/mpeg, image/jpeg, image/x-tiff, image/x-rgb, image/x-xbm, image/gif, */*, application/postscript
    #Content-Type:    application/x-www-form-urlencoded
    #Content-Length:  130
    #URLEncoded form                                                                                                                                                                            [m:auto]
    #NetName:      Test net JUST TESTING
    #Callsign:     KI5ZDF-TIM MORGAN
    #IsNetControl: X
    #Message:      hello just testing https://ragchew.site

    with_lock do
      blocked_stations = (@record.monitors.blocked.pluck(:call_sign).map(&:upcase) + @record.blocked_stations.pluck(:call_sign).map(&:upcase)).uniq
      blocked = blocked_stations.include?(user.call_sign.upcase)
      message_record = @record.messages.create!(
        log_id: nil, # temporary messages don't have a log_id
        call_sign: user.call_sign,
        name: user.first_name.upcase,
        message:,
        sent_at: Time.now,
        blocked: blocked_stations.include?(user.call_sign.upcase),
      )
      Pusher::Client.from_env.trigger(
        "private-net-#{@record.id}",
        'message',
        message: message_record.as_json
      )
    end

    fetcher = Fetcher.new(@record.host)
    fetcher.post(
      'SendInstantMessage.php',
      'NetName' => @record.name,
      'Callsign' => name_for_chat(user),
      'Message' => message,
    )
  rescue Socket::ResolutionError, Net::OpenTimeout, Net::ReadTimeout
    raise ServerError, 'There was an error with the server. Please try again later.'
  end

  def update_station_details!(call_sign, preferred_name:, notes:)
    return unless (club = @record.club)

    club
      .club_stations
      .find_or_initialize_by(call_sign: call_sign.upcase)
      .update!(preferred_name:, notes:)
  end

  def to_log
    @record.checkins.order(:num).map do |checkin|
      [
        checkin.num,
        checkin.call_sign,
        checkin.state,
        checkin.remarks,
        checkin.qsl_info,
        checkin.city,
        checkin.name,
        checkin.status,
        '', # unknown
        '', # unknown
        checkin.county,
        checkin.grid_square,
        checkin.street,
        checkin.zip,
        checkin.dxcc,
        '', # unknown
        '', # unknown
        '', # unknown
        checkin.country,
        checkin.preferred_name,
      ].map { |cell| cell.present? ? cell.to_s.tr('|~`', ' ') : ' ' }.join('|')
    end.join("\n")
  end

  private

  def update_cache(force_full: false)
    begin
      data = fetch(force_full:)
    rescue Socket::ResolutionError, Net::OpenTimeout, Net::ReadTimeout, Errno::EHOSTUNREACH => error
      Honeybadger.notify(error, message: 'Rescued network/server error fetching data')
      return
    end

    changes = update_checkins(data[:checkins], currently_operating: data[:currently_operating])
    changes += update_monitors(data[:monitors])
    changes += update_messages(data[:messages])

    # update this last
    update_net_info(data[:info])

    # let connected clients know
    if changes > 0
      Pusher::Client.from_env.trigger(
        "private-net-#{@record.id}",
        'net-updated',
        changes:,
        updatedAt: @record.updated_at.rfc3339,
      )
    end
  end

  def update_net_info(info)
    update_center
    @record.fully_updated_at = Time.now
    @record.update!(info)
  end

  def update_center
    checkins = @record.checkins.to_a

    minority_factor = (100 - CENTER_PERCENTILE) / 100.0

    latitudes = checkins.map(&:latitude).compact.sort
    minority_lat_size = (latitudes.size * minority_factor).to_i
    if minority_lat_size >= 2
      majority_latitudes = latitudes[(minority_lat_size / 2)...-(minority_lat_size / 2)]
    else
      majority_latitudes = latitudes
    end
    @record.center_latitude = average([majority_latitudes.first, majority_latitudes.last])

    longitudes = checkins.map(&:longitude).compact.sort
    minority_lon_size = (longitudes.size * minority_factor).to_i
    if minority_lon_size >= 2
      majority_longitudes = longitudes[(minority_lon_size / 2)...-(minority_lon_size / 2)]
    else
      majority_longitudes = longitudes
    end
    @record.center_longitude = average([majority_longitudes.first, majority_longitudes.last])

    if majority_latitudes.any? && majority_longitudes.any?
      distance = haversine_distance_in_meters(
        majority_latitudes.first,
        majority_longitudes.first,
        majority_latitudes.last,
        majority_longitudes.last,
      )
      radius = [distance / 2, MIN_CENTER_RADIUS_IN_METERS].max
      @record.center_radius = radius <= MAX_CENTER_RADIUS_TO_SHOW ? radius : nil
    end
  end

  def update_checkins(checkins, currently_operating:)
    records = @record.checkins.to_a

    changes = 0

    checkins.each do |checkin|
      is_new_checkin = false
      is_recheck = records.any? { |r| r.call_sign&.upcase == checkin[:call_sign]&.upcase }
      if (existing = records.detect { |r| r.num == checkin[:num] })
        existing.update!(checkin)
        changes += 1 if existing.previous_changes.any?
      else
        records << @record.checkins.create!(checkin)
        changes += 1
        is_new_checkin = true
      end
      Tables::Station.find_or_initialize_by(call_sign: checkin[:call_sign]).update!(
        last_heard_on: @record.name,
        last_heard_at: checkin[:checked_in_at],
      )

      # Update club station check-in tracking if this net belongs to a club
      if @record.club && is_new_checkin && !is_recheck && checkin[:call_sign].present?
        club_station = @record.club.club_stations.find_or_initialize_by(call_sign: checkin[:call_sign].upcase)
        club_station.first_check_in ||= checkin[:checked_in_at]
        club_station.last_check_in = checkin[:checked_in_at]
        club_station.check_in_count += 1 # we already have a lock so this should be atomic
        club_station.save!
      end

      # Update net station check-in tracking
      if is_new_checkin && !is_recheck && checkin[:call_sign].present?
        net_station = Tables::NetStation.find_or_initialize_by(net_name: @record.name, call_sign: checkin[:call_sign].upcase)
        net_station.first_check_in ||= checkin[:checked_in_at]
        net_station.last_check_in = checkin[:checked_in_at]
        net_station.check_in_count += 1
        net_station.save!
      end
    end

    @record.update_column(:checkin_count, records.size)

    stored_currently_operating = records.detect { |r| r.currently_operating? }&.num
    if currently_operating && stored_currently_operating != currently_operating
      old_record = records.detect { |r| r.num == stored_currently_operating }
      new_record = records.detect { |r| r.num == currently_operating }
      if old_record
        old_record.update!(currently_operating: false)
        changes += 1
      end
      if new_record
        new_record.update!(currently_operating: true)
        changes += 1
      end
    end

    changes
  end

  def update_monitors(monitors)
    changes = 0

    records = @record.monitors.all
    monitors.each do |monitor|
      next unless monitor[:call_sign] =~ /\A[A-Za-z0-9]+\z/

      if (existing = records.detect { |r| r.call_sign == monitor[:call_sign] })
        existing.update!(monitor)
        changes += 1 if existing.previous_changes.any?
      else
        new_monitor = @record.monitors.create!(monitor)
        if @record.blocked_stations.where(call_sign: new_monitor.call_sign).any?
          # was blocked at the beginning, now we need to tell NetLogger
          if (user = net.logging_users.first)
            logger = NetLogger.new(self, user:)
            logger.block_station( call_sign: new_monitor.call_sign)
          end
        end
        changes += 1
      end
    end

    changes
  end

  def update_messages(messages)
    changes = 0

    blocked_stations = @record.monitors.blocked.pluck(:call_sign).map(&:upcase)

    records = @record.messages.all
    messages.each do |message|
      begin
        if (existing = records.detect { |r| r.log_id == message[:log_id] })
          existing.update!(message)
          changes += 1 if existing.previous_changes.any?
        else
          message[:blocked] = blocked_stations.include?(message[:call_sign].upcase)
          @record.messages.create!(message)
          changes += 1
        end
      rescue ActiveRecord::StatementInvalid => error
        Honeybadger.notify(error, message: 'Unable to create/update message')
      end
    end

    temporary_messages_to_cleanup = records.select { |r| r.log_id.nil? }
    temporary_messages_to_cleanup.each(&:destroy)

    changes
  end

  def cache_needs_updating?
    !@record.fully_updated_at || @record.fully_updated_at < Time.now - @record.update_interval_in_seconds
  end

  def fetch(force_full: false)
    data = fetch_raw(force_full:)

    unless data['NetLogger Start Data']
      Honeybadger.notify('No Start Data!', context: data)
    end

    checkins = data['NetLogger Start Data'].map do |num, call_sign, city, state, name, remarks, qsl_info, checked_in_at, county, grid_square, street, zip, status, _unknown, country, dxcc, preferred_name|
      next if call_sign == 'future use 2'

      (latitude, longitude) = GridSquare.new(grid_square).to_a

      begin
        checked_in_at = Time.parse(checked_in_at)
      rescue ArgumentError, TypeError
        # bad checkin?
        nil
      else
        if call_sign.size > 2 && grid_square == ' '
          # The NetLogger operator doesn't have a QRZ account,
          # so we'll look up some info for them using ours.
          begin
            info = qrz.lookup(call_sign)
          rescue Qrz::Error
            # well we tried
          else
            grid_square = info[:grid_square]
            name = [info[:first_name], info[:last_name]].compact.join(' ') unless name.present?
            street = info[:street] unless street.present?
            city = info[:city] unless city.present?
            state = info[:state] unless state.present?
            zip = info[:zip] unless zip.present?
            county = info[:county] unless county.present?
            country = info[:country] unless country.present?
          end
        end

        {
          num: num.to_i,
          call_sign:,
          city:,
          state:,
          name:,
          remarks:,
          qsl_info:,
          checked_in_at:,
          county:,
          grid_square:,
          street:,
          zip:,
          status:,
          country:,
          preferred_name:,
          latitude:,
          longitude:,
        }
      end
    end.compact

    last_record = data['NetLogger Start Data'].last
    if last_record && last_record[0] =~ /^`(\d+)/
      currently_operating = $1.to_i
    end

    monitors = data['NetMonitors Start'].each_with_index.map do |(call_sign_and_info, ip_address), index|
      parts = call_sign_and_info.split(' - ')
      call_sign, name = parts.first.split('-')
      version = parts.grep(/v\d/).last
      status = parts.grep(/(On|Off)line/).first || 'Online'
      {
        num: index,
        call_sign:,
        name:,
        version:,
        status:,
        ip_address:,
      }
    end

    # 2024-08-14 02:36:44|1|KI5ZDF-TIM MORGAN|1031631016|0|3138074|  # type 1 - NCO or Logger probably (not currently handled)
    # 2024-08-14 02:38:22|3|1|3138076|                               # type 3 - block station with index 1
    # 2024-08-14 02:41:34|3|2|3138079|                               # type 3 - block station with index 2
    (data['Ext Data Start'] || []).each do |timestamp, type, index, _serial|
      # I think type 1 means NCO or Logger or something.
      # Type 3 means to block aka shadowban the station so their messages are hidden.
      next unless type.to_i == 3
      next unless (monitor = monitors[index.to_i])

      monitor[:blocked] = true
    end

    messages = data['IM Start'].map do |log_id, call_sign_and_name, _always_one, message, sent_at, ip_address|
      next if call_sign_and_name.nil?

      call_sign, name = call_sign_and_name.split('-', 2).map(&:strip)
      begin
        sent_at = Time.parse(sent_at)
      rescue ArgumentError, TypeError
        # bad message?
        nil
      else
        {
          log_id: log_id.to_i,
          call_sign:,
          name:,
          message:,
          sent_at:,
          ip_address:
        }
      end
    end.compact

    raw_info = (data['Net Info Start'].first || []).each_with_object({}) do |param, hash|
      (key, value) = param.split('=')
      hash[key.downcase] = value
    end
    info = {
      started_at: raw_info['date'],
      frequency: raw_info['frequency'],
      net_logger: raw_info['logger'],
      net_control: raw_info['netcontrol'],
      mode: raw_info['mode'],
      band: raw_info['band'],
      im_enabled: raw_info['aim'] == 'Y',
      update_interval: raw_info['updateinterval'],
      alt_name: raw_info['altnetname'],
    }
    if (last_ext_data = (data['Ext Data Start'] || []).last)
      info[:ext_data_serial] = last_ext_data.last.to_i
    end

    {
      checkins:,
      monitors:,
      messages:,
      info:,
      currently_operating:
    }
  end

  def fetch_raw(force_full: false)
    unless force_full
      log_last_updated_at = @record.checkins.maximum(:checked_in_at)
      im_last_serial = @record.messages.maximum(:log_id)
    end

    fetcher = Fetcher.new(@record.host)
    # LastExtDataSerial=570630

    params = {
      'ProtocolVersion' => '2.3',
      'NetName' => @record.name
    }

    if (log_last_updated_at)
      params.merge!(
        'DeltaUpdateTime' => log_last_updated_at.strftime('%Y-%m-%d %H:%M:%S')
      )
    end

    if (im_last_serial)
      params.merge!(
        'IMSerial' => im_last_serial
      )
    end

    params.merge!('LastExtDataSerial' => @record.ext_data_serial)

    begin
      fetcher.get('GetUpdates3.php', params)
    rescue Fetcher::NotFoundError
      Tables::ClosedNet.from_net(@record).save!
      @record.destroy
      raise NotFoundError, 'Net is closed'
    end
  end

  def name_for_monitoring(user)
    UserPresenter.new(user).name_for_monitoring
  end

  def name_for_chat(user)
    UserPresenter.new(user).name_for_chat
  end

  def median(ary)
    return if ary.empty?

    if ary.size.odd?
      ary[ary.size / 2]
    else
      (ary[(ary.size - 1) / 2] + ary[ary.size / 2]) / 2.0
    end
  end

  def average(ary)
    ary = ary.compact
    return if ary.empty?

    ary.sum / ary.size.to_f
  end

  # https://stackoverflow.com/a/11172685
  def haversine_distance_in_meters(lat1, lon1, lat2, lon2)
    dLat = lat2 * Math::PI / 180 - lat1 * Math::PI / 180
    dLon = lon2 * Math::PI / 180 - lon1 * Math::PI / 180
    a = Math.sin(dLat/2) * Math.sin(dLat/2) +
        Math.cos(lat1 * Math::PI / 180) *
        Math.cos(lat2 * Math::PI / 180) *
        Math.sin(dLon/2) * Math.sin(dLon/2)
    c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1-a))
    d = EARTH_RADIUS_IN_KM * c
    d * 1000
  end

  def qrz
    @qrz ||= QrzAutoSession.new
  end

  def with_lock
    Tables::Net.with_advisory_lock(:update_net_cache, timeout_seconds: LOCK_TIMEOUT) do
      @record.reload
      yield
    end
  end
end
