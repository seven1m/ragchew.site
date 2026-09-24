require 'cgi'
require 'net/http'
require 'uri'

class Qrz
  AGENT = "https://ragchew.site"
  BASE_URL = "https://xmldata.qrz.com/xml/current/"

  class Error < StandardError; end
  class NotACallSign < Error; end
  class NotFound < Error; end
  class WrongUsernamePassword < Error; end
  class SessionTimeout < Error; end
  class ServerError < Error; end

  def initialize(session:)
    @session = session
  end

  attr_reader :session

  def lookup(call_sign)
    call_sign = call_sign.upcase.strip
    raise NotACallSign if call_sign !~ /\A[A-Z]+\d[A-Z]+\z/

    result = self.class.call(s: @session, callsign: call_sign)
    if result =~ /<Error>(.*?)<\/Error>/
      message = $1.strip
      case message
      when /^not found/i
        raise NotFound, message
      when /session timeout/i
        raise SessionTimeout, message
      else
        raise Error, message
      end
    else
      parse_result(result)
    end
  end

  def self.login(username:, password:)
    result = call(username:, password:)
    if result =~ /<Error>(.*?)<\/Error>/m
      message = $1.strip
      if message.downcase == 'username/password incorrect'
        raise WrongUsernamePassword, message
      else
        raise Error, message
      end
    elsif result =~ /<Key>([A-Fa-f0-9]+)<\/Key>/
      new(session: $1)
    else
      raise Error, "unknown error occurred: #{result}"
    end
  end

  def self.call(**params)
    params.merge!(agent: AGENT)
    params_string = params.map { |k, v| "#{k}=#{CGI.escapeURIComponent(v)}" }.join(';')
    url = "#{BASE_URL}?#{params_string}"
    logged_params = params.map do |key, value|
      safe_value = %w[password s].include?(key.to_s.downcase) ? '***' : CGI.escapeURIComponent(value)
      "#{key}=#{safe_value}"
    end.join(';')
    puts "GET #{BASE_URL}?#{logged_params}"
    Net::HTTP.get(URI(url))
  rescue Net::OpenTimeout
    raise ServerError, 'server connection issue'
  end

  private

  def parse_result(result)
    station = Nokogiri::XML(result).at_css('Callsign')
    call_sign = station&.at_css('call')&.content

    raise Error, "unknown error occurred: #{result}" unless call_sign

    {
      call_sign:,
      first_name: station.at_css('fname')&.content,
      last_name: station.at_css('name')&.content,
      image: station.at_css('image')&.content,
      grid_square: station.at_css('grid')&.content,
      street: station.at_css('addr1')&.content,
      city: station.at_css('addr2')&.content,
      state: station.at_css('state')&.content,
      zip: station.at_css('zip')&.content,
      county: station.at_css('county')&.content,
      country: station.at_css('country')&.content,
      dxcc: station.at_css('dxcc')&.content,
      license_class: station.at_css('class')&.content,
      license_date: station.at_css('licdate')&.content,
      expiry_date: station.at_css('expdate')&.content,
      previous_call: station.at_css('p_call')&.content,
      aliases: station.at_css('aliases')&.content,
      trustee: station.at_css('trustee')&.content,
      codes: station.at_css('codes')&.content,
      qsl_manager: station.at_css('qslmgr')&.content,
      email: station.at_css('email')&.content,
      url: station.at_css('url')&.content,
      views: station.at_css('u_views')&.content,
      bio: station.at_css('bio')&.content,
      bio_updated: station.at_css('biodate')&.content,
      moddate: station.at_css('moddate')&.content,
      msa: station.at_css('MSA')&.content,
      area_code: station.at_css('AreaCode')&.content,
      timezone: station.at_css('TimeZone')&.content,
      gmt_offset: station.at_css('GMTOffset')&.content,
      dst: station.at_css('DST')&.content,
      eqsl: station.at_css('eqsl')&.content,
      mqsl: station.at_css('mqsl')&.content,
      cqzone: station.at_css('cqzone')&.content,
      ituzone: station.at_css('ituzone')&.content,
      born: station.at_css('born')&.content,
      user: station.at_css('user')&.content,
      lotw: station.at_css('lotw')&.content,
      iota: station.at_css('iota')&.content,
      geoloc: station.at_css('geoloc')&.content,
      attn: station.at_css('attn')&.content,
      nickname: station.at_css('nickname')&.content,
      name_fmt: station.at_css('name_fmt')&.content,
    }
  end
end
