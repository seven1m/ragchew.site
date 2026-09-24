require 'time'

require_relative './tables'

class NetList
  CACHE_LENGTH_IN_SECONDS = 60
  REQUIRED_FETCHED_NET_FIELDS = %i[name started_at].freeze
  Error = Class.new(StandardError)
  ServerError = Class.new(Error)
  ParseError = Class.new(Error)

  def list(order: :name)
    update_cache
    scope = Tables::Net.left_outer_joins(:canonical_net).includes(:club, :canonical_net).order(order)
    scope = scope.where.not(name: APPLE_REVIEW_DEMO_NET_NAME) unless APPLE_REVIEW_DEMO_ENABLED
    scope.to_a
  end

  def update_net_list_right_now_with_wreckless_disregard_for_the_last_update!
    Tables::Net.with_advisory_lock(:update_net_list_cache, timeout_seconds: 2) do
      update_net_cache(force: true)
    end
  end

  private

  def update_cache
    return unless net_cache_needs_updating?

    Tables::Net.with_advisory_lock(:update_net_list_cache, timeout_seconds: 2) do
      update_net_cache if net_cache_needs_updating?
    end
  end

  def update_net_cache(force: false)
    return unless force || net_cache_needs_updating?

    catalog = Backend.remote.fetch_active_nets
    now = Time.now
    existing_servers = Tables::Server.all.index_by(&:name)
    existing_nets = Tables::Net.where.not(host: 'ragchew.site').index_by { |net| [net.server_id, net.name] }
    blocked_names = Tables::BlockedNet.pluck(:name)

    catalog.each do |server_name, nets|
      server = existing_servers.delete(server_name) || Tables::Server.new(
        name: server_name,
        host: host_for(server_name),
        club_info_list_url: 'https://www.netlogger.org/downloads/ClubInfoList.txt'
      )
      server.update!(is_public: true, state: 'Public', net_list_fetched_at: now)

      nets.each do |attributes|
        missing = REQUIRED_FETCHED_NET_FIELDS.select { |field| attributes[field].blank? }
        if missing.any?
          Honeybadger.notify('Skipping a fetched net with missing required fields.', context: { server_name:, missing_fields: missing })
          next
        end
        next if Tables::BlockedNet.blocked?(attributes[:name], names: blocked_names)

        key = [server.id, attributes[:name]]
        net = existing_nets.delete(key)
        if net
          attributes[:echolink] = Echolink.parse_frequency(attributes[:frequency]) if net.echolink.blank?
          net.update!(attributes.merge(host: server.host))
        else
          net = Tables::Net.new(attributes.merge(server:, host: server.host))
          net.echolink = Echolink.parse_frequency(net.frequency)
          AssociateNetWithClub.new(net).call
          net.save!
        end
      end
    end

    existing_nets.each_value do |net|
      Tables::ClosedNet.from_net(net).save! if net.started_at.present?
      net.destroy!
    end
    existing_servers.each_value do |server|
      server.destroy! unless server.nets.exists?
    end
    Tables::Net.where.not(host: 'ragchew.site').update_all(partially_updated_at: now)
  rescue NetloggerXML::RateLimited
    nil
  rescue Socket::ResolutionError, Net::OpenTimeout, Net::ReadTimeout, Errno::EHOSTUNREACH, NetloggerXML::Error => error
    Honeybadger.notify(error, message: 'Unable to refresh NetLogger active nets')
  end

  def net_cache_needs_updating?
    fetched_at = Tables::Server.maximum(:net_list_fetched_at)
    fetched_at.nil? || fetched_at < Time.now - CACHE_LENGTH_IN_SECONDS
  end

  def host_for(server_name)
    return 'www.netlogger.org' if server_name == 'NETLOGGER'

    suffix = server_name[/\ANETLOGGER(\d+)\z/i, 1]
    suffix ? "www.netlogger#{suffix}.org" : 'www.netlogger.org'
  end
end
