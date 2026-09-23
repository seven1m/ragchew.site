require_relative "../netlogger_xml"
require_relative "../grid_square"
require_relative "../user_presenter"

module Backend
  class RemoteNet
    CHECKIN_INTERVAL = Tables::Net::UPDATE_INTERVAL_IN_SECONDS
    AIM_INTERVAL = Tables::Net::UPDATE_INTERVAL_IN_SECONDS
    MONITOR_INTERVAL = 60
    FEED_ERROR_BACKOFF = 30

    def initialize(net_info, user: nil, require_logger_auth: false)
      @net_info = net_info
      @client = NetloggerXML.new
      if require_logger_auth
        raise Backend::Logger::NotAuthorizedError,
              "External nets are read-only."
      end
    end

    def self.fetch_active_nets
      document = NetloggerXML.new.get("GetActiveNets.php")
      unless document.at_xpath("/NetLoggerXML/ServerList")
        raise NetloggerXML::Error, "NetLogger API omitted ServerList"
      end

      servers = document.xpath("/NetLoggerXML/ServerList/Server")
      if servers.empty?
        raise NetloggerXML::Error, "NetLogger API returned no servers"
      end

      servers
        .map do |node|
          name = NetloggerXML.text(node, "ServerName")
          next if name.blank?

          [
            name,
            node
              .xpath("./Net")
              .map do |net|
                {
                  name: NetloggerXML.text(net, "NetName"),
                  alt_name: NetloggerXML.text(net, "AltNetName"),
                  frequency: NetloggerXML.text(net, "Frequency"),
                  net_logger: NetloggerXML.text(net, "Logger"),
                  net_control: NetloggerXML.text(net, "NetControl"),
                  started_at: NetloggerXML.time(NetloggerXML.text(net, "Date")),
                  mode: NetloggerXML.text(net, "Mode"),
                  band: NetloggerXML.text(net, "Band"),
                  subscribers: NetloggerXML.text(net, "SubscriberCount").to_i
                }
              end
          ]
        end
        .compact
    end

    def fetch_updates(
      force_full: false,
      include_aim: true,
      include_monitors: true
    )
      net = @net_info.net
      now = Time.now
      params = { "ServerName" => net.server.name, "NetName" => net.name }
      result = {
        checkins: nil,
        monitors: nil,
        messages: nil,
        info: {
        },
        currently_operating: nil
      }
      fetched = {}

      if due?(net.checkins_fetched_at, CHECKIN_INTERVAL, force_full)
        fetch_feed("GetCheckins.php", result, :checkins) do
          document = @client.get("GetCheckins.php", params, empty: true)
          list = document.at_xpath("/NetLoggerXML/CheckinList")
          unless list || NetloggerXML.empty_result?(document)
            raise NetloggerXML::Error, "NetLogger API omitted CheckinList"
          end
          observed_at =
            begin
              Time.strptime(
                "#{NetloggerXML.text(document.at_xpath("/NetLoggerXML/Header"), "CreationDateUTC")} UTC",
                "%a %m/%d/%Y %H:%M:%S %Z"
              )
            rescue StandardError
              now
            end
          result[:checkins] = list
            &.xpath("./Checkin")
            &.filter_map do |node|
              num = NetloggerXML.text(node, "SerialNo").to_i
              next if num <= 0

              grid = NetloggerXML.text(node, "Grid")
              latitude, longitude = GridSquare.new(grid).to_a
              {
                num:,
                call_sign: NetloggerXML.text(node, "Callsign"),
                name: NetloggerXML.text(node, "FirstName"),
                city: NetloggerXML.text(node, "CityCountry"),
                state: NetloggerXML.text(node, "State"),
                remarks: NetloggerXML.text(node, "Remarks"),
                qsl_info: NetloggerXML.text(node, "QSLInfo"),
                county: NetloggerXML.text(node, "County"),
                grid_square: grid,
                street: NetloggerXML.text(node, "Street"),
                zip: NetloggerXML.text(node, "Zip"),
                status: NetloggerXML.text(node, "Status"),
                country: NetloggerXML.text(node, "Country"),
                dxcc: NetloggerXML.text(node, "DXCC"),
                preferred_name: NetloggerXML.text(node, "PreferredName"),
                checked_in_at: observed_at,
                latitude:,
                longitude:
              }
            end || []
          result[:currently_operating] = NetloggerXML.text(list, "Pointer").to_i
          fetched[:checkins_fetched_at] = now
        end
      end

      if include_aim && due?(net.aim_fetched_at, AIM_INTERVAL, force_full)
        fetch_feed("GetAIM.php", result, :messages) do
          cursor = net.aim_next_request_id || -100
          document =
            @client.get("GetAIM.php", params.merge("id" => cursor), empty: true)
          transcript = document.at_xpath("/NetLoggerXML/AIMTranscript")
          unless transcript || NetloggerXML.empty_result?(document)
            raise NetloggerXML::Error, "NetLogger API omitted AIMTranscript"
          end
          result[:messages] = transcript
            &.xpath("./AIMEntry")
            &.filter_map do |node|
              id = NetloggerXML.text(node, "id").to_i
              next if id <= 0

              call_sign, name =
                NetloggerXML.text(node, "Callsign").to_s.split("-", 2)
              {
                log_id: id,
                call_sign:,
                name: name.to_s.strip,
                message: NetloggerXML.text(node, "Message"),
                sent_at: NetloggerXML.time(NetloggerXML.text(node, "aim_time")),
                ip_address: NetloggerXML.text(node, "IP_ADDR")
              }
            end || []
          next_id =
            (
              if transcript
                NetloggerXML.text(transcript, "AIMNextRequestID")
              else
                cursor
              end
            )
          if next_id.blank?
            raise NetloggerXML::Error, "NetLogger API omitted AIM cursor"
          end

          fetched[:aim_fetched_at] = now
          fetched[:aim_next_request_id] = next_id.to_i
        end
      end

      if include_monitors &&
           due?(net.monitors_fetched_at, MONITOR_INTERVAL, force_full)
        fetch_feed("GetMonitors.php", result, :monitors) do
          document = @client.get("GetMonitors.php", params, empty: true)
          list = document.at_xpath("/NetLoggerXML/MonitorList")
          unless list || NetloggerXML.empty_result?(document)
            raise NetloggerXML::Error, "NetLogger API omitted MonitorList"
          end
          result[:monitors] = list
            &.xpath("./Monitor")
            &.each_with_index
            &.filter_map do |node, index|
              operator =
                NetloggerXML.text(node, "Operator") ||
                  NetloggerXML.text(node, "Callsign").to_s.split(" - ").first
              call_sign, name = operator.to_s.split("-", 2)
              next if call_sign.blank?

              {
                num: NetloggerXML.text(node, "MonitorIndex")&.to_i || index,
                call_sign:,
                name: name.to_s.strip,
                version:
                  NetloggerXML.text(node, "Version") ||
                    NetloggerXML.text(node, "Callsign").to_s[/v\S+/],
                status:
                  (
                    if NetloggerXML.text(node, "OfflineStatus") == "TRUE" ||
                         NetloggerXML
                           .text(node, "Callsign")
                           .to_s
                           .include?("Offline")
                      "Offline"
                    else
                      "Online"
                    end
                  )
              }
            end || []
          fetched[:monitors_fetched_at] = now
        end
      end

      net.update_columns(fetched) if fetched.any?
      fetched.any? ? result : nil
    end

    def subscribe!(user:)
      participation!(
        "SubscribeToNet.php",
        user,
        "Callsign" => UserPresenter.new(user).name_for_chat
      )
    end

    def unsubscribe!(user:)
      participation!(
        "UnSubscribeFromNet.php",
        user,
        "Callsign" => UserPresenter.new(user).name_for_chat
      )
    end

    def send_message!(user:, message:)
      participation!(
        "SendAIMMessage.php",
        user,
        "Callsign" => UserPresenter.new(user).name_for_chat,
        "Message" => message
      )
    end

    def self.start_logging(*)
      raise Backend::Logger::NotAuthorizedError, "External nets are read-only."
    end

    private

    def due?(fetched_at, interval, force)
      force || fetched_at.nil? || fetched_at < Time.now - interval
    end

    def fetch_feed(endpoint, result, field)
      backoff_key = "netlogger:feed_error:#{endpoint}:#{@net_info.id}"
      return if REDIS.exists?(backoff_key)

      yield
    rescue NetloggerXML::Error,
           Socket::ResolutionError,
           Net::OpenTimeout,
           Net::ReadTimeout,
           Errno::EHOSTUNREACH,
           Errno::ECONNRESET => error
      result[field] = nil
      REDIS.set(backoff_key, "1", ex: FEED_ERROR_BACKOFF)
      Honeybadger.notify("NetLogger #{endpoint} fetch failed (#{error.class})")
    end

    def participation!(endpoint, user, extra)
      if user.test_user?
        raise Backend::Logger::NotAuthorizedError,
              "Test users cannot mutate NetLogger servers."
      end

      cooldown = endpoint == "SendAIMMessage.php" ? 30 : 60
      cooldown_key = "netlogger:cooldown:#{endpoint}:#{@net_info.id}:#{user.id}"
      acquired = REDIS.set(cooldown_key, "1", nx: true, ex: cooldown)
      unless acquired
        raise NetloggerXML::RateLimited,
              "Please wait before repeating this action."
      end

      params = {
        "ServerName" => @net_info.net.server.name,
        "NetName" => @net_info.name
      }.merge(extra)
      @client.authorized_get(endpoint, params)
    rescue StandardError
      REDIS.del(cooldown_key) if acquired
      raise
    end
  end
end
