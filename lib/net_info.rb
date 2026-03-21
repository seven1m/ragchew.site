require 'time'

require_relative './tables'

class NetInfo
  EARTH_RADIUS_IN_KM = 6378.137
  CENTER_PERCENTILE = 75
  MIN_LATITUDES_FOR_MAJORITY = 3
  MIN_LONGITUDES_FOR_MAJORITY = 3
  MIN_CENTER_RADIUS_IN_METERS = 50000
  MAX_CENTER_RADIUS_TO_SHOW = 3000000
  LOCK_TIMEOUT = 2
  FAVORITE_CALL_SIGNS_CACHE_KEY = 'fav_callsigns'
  FAVORITE_CALL_SIGNS_CACHE_TTL = 60 * 60
  FAVORITE_CALL_SIGNS_CACHE_EMPTY_SENTINEL = '__EMPTY__'
  MESSAGES_COUNT_TO_PARSE_FOR_ECHOLINK = 5

  class NotFoundError < StandardError; end
  class ServerError < StandardError; end
  class PasswordIncorrectError < StandardError; end
  class NotAuthorizedError < StandardError; end
  class CouldNotCloseError < StandardError; end
  class CouldNotCreateError < StandardError; end
  class CouldNotFindAfterCreationError < StandardError; end

  def self.create!(ragchew_only_testing_net:, **kwargs)
    Backend::Logger.create_net!(ragchew_only_testing_net:, **kwargs)
  rescue Backend::Logger::CouldNotCreateNetError => error
    raise CouldNotCreateError, error.message
  rescue Backend::Logger::CouldNotFindNetAfterCreationError => error
    raise CouldNotFindAfterCreationError, error.message
  end

  def self.start_logging!(id:, password:, user:)
    service = new(id:)
    Backend::Logger.start_logging(service, password:, user:)
    service
  rescue Backend::Logger::PasswordIncorrectError => error
    raise PasswordIncorrectError, error.message
  end

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
  def id = @record.id
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

    begin
      backend_for_user(user).subscribe!(user:)
      user.update!(
        monitoring_net: @record,
        monitoring_net_last_refreshed_at: Time.now,
      )
    rescue Backend::Logger::NotAuthorizedError => error
      raise NotAuthorizedError, error.message
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

    begin
      backend_for_user(user).unsubscribe!(user:)
    rescue Backend::Logger::NotAuthorizedError => error
      raise NotAuthorizedError, error.message
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

    raise NotAuthorizedError, 'Test users cannot mutate NetLogger servers.' if user.test_user? && !@record.ragchew_only_testing_net?

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

    backend_for_user(user).send_message!(user:, message:)
  rescue Backend::Logger::NotAuthorizedError => error
    raise NotAuthorizedError, error.message
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

  def update_log_entry!(num:, params:, user:)
    backend_for_user(user, require_logger_auth: true).update!(num, params)
  rescue Backend::Logger::NotAuthorizedError => error
    raise NotAuthorizedError, error.message
  end

  def delete_log_entry!(num:, user:)
    backend_for_user(user, require_logger_auth: true).delete!(num)
  rescue Backend::Logger::NotAuthorizedError => error
    raise NotAuthorizedError, error.message
  end

  def current_highlight_num(user:)
    backend_for_user(user, require_logger_auth: true).current_highlight_num
  rescue Backend::Logger::NotAuthorizedError => error
    raise NotAuthorizedError, error.message
  end

  def highlight!(num:, user:)
    backend_for_user(user, require_logger_auth: true).highlight!(num)
  rescue Backend::Logger::NotAuthorizedError => error
    raise NotAuthorizedError, error.message
  end

  def block_station!(call_sign:, user:)
    backend_for_user(user, require_logger_auth: true).block_station(call_sign:)
  rescue Backend::Logger::NotAuthorizedError => error
    raise NotAuthorizedError, error.message
  end

  def close!(user:)
    backend_for_user(user, require_logger_auth: true).close_net!
  rescue Backend::Logger::NotAuthorizedError => error
    raise NotAuthorizedError, error.message
  rescue Backend::Logger::CouldNotCloseNetError => error
    raise CouldNotCloseError, error.message
  end

  private

  def update_cache(force_full: false)
    begin
      data = backend_for_update.fetch_updates(force_full:)
    rescue Socket::ResolutionError, Net::OpenTimeout, Net::ReadTimeout, Errno::EHOSTUNREACH => error
      Honeybadger.notify(error, message: 'Rescued network/server error fetching data')
      return
    end
    return unless data

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
    parsed_echolink = Echolink.parse_frequency(info[:frequency])
    info[:echolink] = parsed_echolink if parsed_echolink.present?
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
    new_call_signs = []

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

        new_call_signs << checkin[:call_sign]
      end
    end

    if new_call_signs.any?
      call_sign_map = new_call_signs.index_by(&:upcase)

      # Use redis for quick check to see if any of these call signs are favorited by any user.
      favorited = favorited_call_signs(call_sign_map.keys)

      if favorited.any?
        # Query necessary because we need to know which users to send notifications to.
        Tables::Favorite.where(call_sign: favorited)
                        .includes(user: :devices)
                        .find_each do |fave|
          call_sign = call_sign_map[fave.call_sign]
          fave.user.devices.each do |device|
            next unless device.should_send_notification?(:favorite_station)

            device.send_push_notification(
              body: "#{call_sign} checked into #{@record.name}",
              data: { callSign: call_sign, netName: @record.name }
            )
          end
        end
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
            logger = Backend::Logger.new(self, user:, require_logger_auth: true)
            logger.block_station( call_sign: new_monitor.call_sign)
          end
        end
        changes += 1
      end
    end

    changes
  end

  def favorited_call_signs(call_signs)
    ensure_favorite_call_sign_cache!
    hits = REDIS.smismember(FAVORITE_CALL_SIGNS_CACHE_KEY, *call_signs)
    call_signs.zip(hits).filter_map { |cs, hit| cs if hit }
  end

  def ensure_favorite_call_sign_cache!
    return if REDIS.exists?(FAVORITE_CALL_SIGNS_CACHE_KEY)

    call_signs = Tables::Favorite.distinct.pluck(:call_sign)
    members = call_signs.empty? ? [FAVORITE_CALL_SIGNS_CACHE_EMPTY_SENTINEL] : call_signs

    REDIS.multi do |pipeline|
      pipeline.del(FAVORITE_CALL_SIGNS_CACHE_KEY)
      pipeline.sadd(FAVORITE_CALL_SIGNS_CACHE_KEY, *members)
      pipeline.expire(FAVORITE_CALL_SIGNS_CACHE_KEY, FAVORITE_CALL_SIGNS_CACHE_TTL)
    end
  end

  def update_messages(messages)
    changes = 0

    blocked_stations = @record.monitors.blocked.pluck(:call_sign).map(&:upcase)

    records = @record.messages.to_a
    messages.each do |message|
      begin
        if (existing = records.detect { |r| r.log_id == message[:log_id] })
          existing.update!(message)
          changes += 1 if existing.previous_changes.any?
        else
          message[:blocked] = blocked_stations.include?(message[:call_sign].upcase)
          records << @record.messages.create!(message)
          changes += 1
        end
      rescue ActiveRecord::StatementInvalid => error
        Honeybadger.notify(error, message: 'Unable to create/update message')
      end
    end

    # FIXME: there is race here: we sometimes delete temporary messages if the netlogger
    # fetch was in-flight and doesn't have the new message record.
    temporary_messages_to_cleanup = records.select { |r| r.log_id.nil? }
    temporary_messages_to_cleanup.each(&:destroy)

    maybe_set_echolink_from_messages!(records)

    changes
  end

  def maybe_set_echolink_from_messages!(messages)
    return if @record.echolink.present?

    echolink = messages
                 .sort_by(&:sent_at)
                 .first(MESSAGES_COUNT_TO_PARSE_FOR_ECHOLINK)
                 .filter_map { |message| Echolink.parse_message(message.message) }
                 .first
    @record.update!(echolink:) if echolink
  end

  def cache_needs_updating?
    !@record.fully_updated_at || @record.fully_updated_at < Time.now - @record.update_interval_in_seconds
  end

  def backend_for_update
    Backend::Logger.new(self)
  end

  def backend_for_user(user, require_logger_auth: false)
    Backend::Logger.new(self, user:, require_logger_auth:)
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

  def with_lock
    Tables::Net.with_advisory_lock(:update_net_cache, timeout_seconds: LOCK_TIMEOUT) do
      @record.reload
      yield
    end
  end
end
