require "net/http"
require "nokogiri"

class NetloggerXML
  BASE_URL = "https://www.netlogger.org/api/"
  USER_AGENT = "RagChew/1.0 (+https://ragchew.site)"
  SESSION_CACHE_KEY = "netlogger:api_session"

  class Error < StandardError
  end
  class RateLimited < Error
  end
  class NotFound < Error
  end
  class Unauthorized < Error
  end

  def self.text(node, name)
    node&.at_xpath("./#{name}")&.text&.strip
  end

  def self.time(value)
    Time.strptime("#{value} UTC", "%Y-%m-%d %H:%M:%S %Z") if value.present?
  rescue ArgumentError
    nil
  end

  def self.empty_result?(document)
    document
      .at_xpath("/NetLoggerXML/ResponseCode")
      &.text
      .to_s
      .start_with?("404") &&
      document
        .at_xpath("/NetLoggerXML/Error")
        &.text
        .to_s
        .match?(/query returned an empty result/i)
  end

  def get(endpoint, params = {}, empty: false)
    if REDIS.exists?("netlogger:rate_limited:#{endpoint}")
      raise RateLimited, "NetLogger API rate limited the request"
    end

    uri = URI.join(BASE_URL, endpoint)
    uri.query = URI.encode_www_form(params)
    response =
      Net::HTTP.start(
        uri.host,
        uri.port,
        use_ssl: true,
        open_timeout: 5,
        read_timeout: 10
      ) { |http| http.get(uri.request_uri, "User-Agent" => USER_AGENT) }
    if response.code.to_i == 429
      REDIS.set("netlogger:rate_limited:#{endpoint}", "1", ex: 60)
      raise RateLimited, "NetLogger API rate limited the request"
    end
    unless response.is_a?(Net::HTTPSuccess)
      raise Error, "NetLogger API HTTP #{response.code}"
    end

    document = Nokogiri.XML(response.body) { |config| config.strict.nonet }
    unless document.root&.name == "NetLoggerXML"
      raise Error, "Invalid NetLogger API XML"
    end

    code =
      document.at_xpath("/NetLoggerXML/ResponseCode") ||
        document.at_xpath("/NetLoggerXML/ServerList/ResponseCode") ||
        document.at_xpath("/NetLoggerXML/CheckinList/ResponseCode") ||
        document.at_xpath("/NetLoggerXML/AIMTranscript/ResponseCode") ||
        document.at_xpath("/NetLoggerXML/MonitorList/ResponseCode") ||
        document.at_xpath("/NetLoggerXML/Session/ResponseCode")
    status = code&.text.to_s.to_i
    case status
    when 200
      document
    when 404
      root_error = code.parent == document.root
      if empty && (!root_error || self.class.empty_result?(document))
        document
      else
        raise(NotFound, "NetLogger API resource not found")
      end
    when 401, 403
      raise Unauthorized, "NetLogger API authorization failed"
    when 429
      REDIS.set("netlogger:rate_limited:#{endpoint}", "1", ex: 60)
      raise RateLimited, "NetLogger API rate limited the request"
    else
      raise Error, "NetLogger API response #{status.zero? ? "missing" : status}"
    end
  rescue Nokogiri::XML::SyntaxError
    raise Error, "Invalid NetLogger API XML"
  end

  def authorized_get(endpoint, params)
    key = session_key
    begin
      response = get(endpoint, params.merge("SessionKey" => key))
    rescue Unauthorized
      REDIS.del(SESSION_CACHE_KEY)
      response = get(endpoint, params.merge("SessionKey" => session_key))
    end
    ttl = self.class.text(response.root, "TTL")&.to_i
    REDIS.del(SESSION_CACHE_KEY) if ttl && ttl < 128
    response
  end

  def session_key
    cached = REDIS.get(SESSION_CACHE_KEY)
    return cached if cached.present?

    Tables::Net.with_advisory_lock(
      :netlogger_api_session,
      timeout_seconds: 5
    ) do
      REDIS.get(SESSION_CACHE_KEY).presence ||
        begin
          api_key = ENV.fetch("NETLOGGER_API_KEY")
          response = get("GetNewAPISessionKey.php", { "APIKey" => api_key })
          key =
            self.class.text(
              response.at_xpath("/NetLoggerXML/Session"),
              "SessionKey"
            )
          raise Error, "NetLogger API returned no session key" if key.blank?

          REDIS.set(SESSION_CACHE_KEY, key)
          key
        end
    end
  end
end
