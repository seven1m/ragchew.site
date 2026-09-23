require_relative './tables'
require 'open-uri'

class UpdateClubList
  def call
    clubs.each do |club_name, url|
      begin
        raw = club_info(url)
      rescue SocketError, Errno::EBUSY => e
        puts "error: could not get #{url} (#{e.message})"
      else
        config = parse_config(raw)
        next unless config['Variables']

        variables = config['Variables'].each_with_object({}) do |line, hash|
          name, value = line.split(/\s*=\s*/, 2)
          hash[name] = value
        end

        club = Tables::Club.find_or_initialize_by(name: club_name)

        about_url = if club.override_about_url?
                      club.about_url
                    else
                      variables['AboutURL']
                    end
        logo_url = if club.override_logo_url?
                     club.logo_url
                   else
                     download_logo_url(club, variables['LogoURL'])
                   end

        club.update!(
          profile_url: url,
          about_url:,
          logo_url:,
          logo_updated_at: variables['LogoTimeStamp'],
          expiration_time: variables['ExpirationTime'],
          current_net_expiration_time: variables['CurrentNetExpirationTime'],
          net_patterns: config['Nets'],
          net_list: net_list(config['NetList']),
        )
        AssociateClubWithNets.new(club, only_blank: true).call
      end
    end

    AssociateNetWithClub.clear_clubs_cache
  end

  private

  def net_list(lines)
    (lines || []).map do |line|
      name, band, frequency, mode, host = line.split(/\s*\|\s*/)
      {
        name:,
        band:,
        frequency:,
        mode:,
        host:,
      }
    end
  end

  def clubs
    hash = {}
    Tables::Server.all.map(&:club_info_list_url).compact.uniq.each do |url|
      text = Net::HTTP.get(URI(url)).force_encoding('ISO-8859-1')
      section = parse_config(text)['ClubInfoList']
      section.grep_v(/^\s*#|^\s*$/).each do |line|
        club, url = line.strip.split(/\s*\|\s*/)
        hash[club] = url
      end
    end
    hash
  end

  def club_info(url)
    Net::HTTP.get(URI(url))
  end

  def parse_config(text)
    sections = {}
    section = nil
    text.split(/\r?\n/).each do |line|
      if line =~ /^\[(.+)\]/
        section = $1
      else
        sections[section] ||= []
        sections[section] << line if line.present? && !line.start_with?('#')
      end
    end
    sections
  end

  def download_logo_url(club, url)
    self.class.download_logo_url(club, url)
  end

  def self.download_logo_url(club, url)
    return unless url.present?

    uri = URI(url)
    return url if uri.host.nil?

    safe_name = club.name.gsub(/[^a-z0-9]/i, '_')
    extension = uri.path.split('.').last
    public_path = "/images/clubs/#{safe_name}.#{club.id}.#{extension}"
    path = File.expand_path("../public#{public_path}", __dir__)

    begin
      URI.open(uri, 'rb') do |file|
        File.write(path, file.read)
      end
    rescue OpenURI::HTTPError, Socket::ResolutionError
      return nil
    end

    public_path
  end
end
