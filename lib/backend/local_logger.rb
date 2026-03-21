require_relative '../tables'
require_relative '../user_presenter'

module Backend
  class LocalLogger
    def initialize(net_info, user: nil, require_logger_auth: false)
      @net_info = net_info
      if require_logger_auth && (!user || user.logging_net != @net_info.net)
        raise Backend::Logger::NotAuthorizedError, 'You are not authorized to access this net.'
      end
      @password = user&.logging_password
    end

    attr_reader :net_info, :password

    def subscribe!(user:)
      monitor_name = UserPresenter.new(user).name_for_monitoring
      call_sign, name_and_version = monitor_name.split('-', 2)
      name, version = name_and_version.to_s.split(' - ', 2)
      monitor = net_info.net.monitors.find_or_initialize_by(call_sign: call_sign)

      monitor.update!(
        num: monitor.num || next_monitor_num,
        name: name,
        version: version,
        status: 'Online',
        blocked: net_info.net.blocked_stations.where(call_sign: call_sign).exists?
      )
    end

    def unsubscribe!(user:)
      net_info.net.monitors.where(call_sign: user.call_sign.upcase).delete_all
    end

    def send_message!(user:, message:); end

    def insert!(num, entry)
      net = net_info.net
      net.checkins.where('num >= ?', num).order(num: :desc).each do |existing|
        existing.update!(num: existing.num + 1)
      end
      net.checkins.create!(checkin_attributes(entry).merge(num:))
      net_info.update_station_details!(entry[:call_sign], preferred_name: entry[:preferred_name], notes: entry[:notes])
    end

    def update!(num, entry)
      net = net_info.net
      existing = net.checkins.find_by(num:)
      if existing
        existing.update!(checkin_attributes(entry))
      else
        net.checkins.create!(checkin_attributes(entry).merge(num:))
      end
      if entry[:call_sign].present?
        net_info.update_station_details!(entry[:call_sign], preferred_name: entry[:preferred_name], notes: entry[:notes])
      end
    end

    def delete!(num)
      net = net_info.net
      net.checkins.where(num:).delete_all
      net.checkins.where('num > ?', num).order(:num).each do |entry|
        entry.update!(num: entry.num - 1)
      end
    end

    def highlight!(num)
      net = net_info.net
      net.checkins.update_all(currently_operating: false)
      net.checkins.where(num:).update_all(currently_operating: true)
    end

    def next_num
      net_info.net.checkins.not_blank.maximum(:num).to_i + 1
    end

    def block_station(call_sign:)
      call_sign = call_sign.strip.upcase
      net_info.net.blocked_stations.find_or_create_by(call_sign:)
    end

    def close_net!
      Tables::ClosedNet.from_net(net_info.net).save!
      net_info.net.destroy
    end

    def current_highlight_num
      net_info.net.checkins.find_by(currently_operating: true)&.num || 0
    end

    def self.create_net!(club:, name:, password:, frequency:, net_control:, user:, mode:, band:, enable_messaging: true, update_interval: 20000, misc_net_parameters: nil, host: 'www.netlogger.org', blocked_stations: [])
      net = Tables::Net.create!(
        name:,
        frequency:,
        echolink: Echolink.parse_frequency(frequency),
        mode:,
        net_control:,
        net_logger: UserPresenter.new(user).name_for_logging,
        band:,
        started_at: Time.now,
        im_enabled: enable_messaging,
        update_interval:,
        subscribers: 0,
        host: 'ragchew.site',
        created_by_ragchew: true,
        ragchew_only_testing_net: true,
      )

      if club.nil?
        AssociateNetWithClub.new(net).call
        club = net.club
      end

      net.update!(club:, created_by_ragchew: true)
      user.update!(logging_net: net, logging_password: password)

      logger = new(NetInfo.new(id: net.id), user:, require_logger_auth: true)
      if blocked_stations.is_a?(Array)
        blocked_stations.each do |call_sign|
          logger.block_station(call_sign:)
        end
      end
    end

    def self.start_logging(net_info, password:, user:)
      user.update!(logging_net: net_info.net, logging_password: password)
    end

    def self.fetch_server_catalog!
      []
    end

    def self.fetch_nets_in_progress(servers:)
      []
    end

    def fetch_updates(force_full: false)
      nil
    end

    private

    def checkin_attributes(entry)
      entry.to_h.symbolize_keys.slice(*checkin_attribute_keys)
    end

    def checkin_attribute_keys
      @checkin_attribute_keys ||= (
        Tables::Checkin.column_names.map(&:to_sym) -
        %i[id net_id created_at updated_at]
      )
    end

    def next_monitor_num
      net_info.net.monitors.maximum(:num).to_i + 1
    end
  end
end
