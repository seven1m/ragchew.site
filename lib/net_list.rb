require 'time'

require_relative './tables'

class NetList
  CACHE_LENGTH_IN_SECONDS = 30
  SERVER_CACHE_LENGTH_IN_SECONDS = 3600
  Error = Class.new(StandardError)
  ServerError = Class.new(Error)
  ParseError = Class.new(Error)

  def list(order: :name, include_testing: true)
    update_cache
    scope = Tables::Net.includes(:club).order(order)
    scope = scope.where(ragchew_only_testing_net: false) unless include_testing
    scope.to_a
  end

  def update_net_list_right_now_with_wreckless_disregard_for_the_last_update!
    Tables::Net.with_advisory_lock(:update_net_list_cache, timeout_seconds: 2) do
      update_net_cache(force: true)
    end
  end

  private

  def update_cache
    if server_cache_needs_updating?
      Tables::Net.with_advisory_lock(:update_server_list_cache, timeout_seconds: 2) do
        if server_cache_needs_updating?
          update_server_cache
        end
      end
    end

    if net_cache_needs_updating?
      Tables::Net.with_advisory_lock(:update_net_list_cache, timeout_seconds: 2) do
        if net_cache_needs_updating?
          update_net_cache
        end
      end
    end
  end

  def update_server_cache
    return unless server_cache_needs_updating?

    cached = Tables::Server.by_host

    # add new and update existing
    fetch_server_catalog.each do |server_info|
      host = server_info.fetch(:host)
      record = cached.delete(host) || Tables::Server.new(host:)
      record.update!(
        name: server_info[:name],
        state: server_info[:state],
        is_public: server_info[:is_public],
        server_created_at: server_info[:server_created_at],
        min_aim_interval: server_info[:min_aim_interval],
        default_aim_interval: server_info[:default_aim_interval],
        token_support: server_info[:token_support],
        delta_updates: server_info[:delta_updates],
        ext_data: server_info[:ext_data],
        timestamp_utc_offset: server_info[:timestamp_utc_offset],
        club_info_list_url: server_info[:club_info_list_url],
        updated_at: Time.now,
      )
    end

    # delete old
    cached.values.each(&:destroy)
  end

  def server_cache_needs_updating?
    last_updated = Tables::Server.maximum(:updated_at)
    !last_updated || last_updated < Time.now - SERVER_CACHE_LENGTH_IN_SECONDS
  end

  def update_net_cache(force: false)
    return unless force || net_cache_needs_updating?

    data = fetch
    cached = Tables::Net.where(ragchew_only_testing_net: false).each_with_object({}) do |net, hash|
      hash[net.name] = net
    end

    blocked_net_names = Tables::BlockedNet.pluck(:name)
    data.reject! do |net_info|
      Tables::BlockedNet.blocked?(net_info[:name], names: blocked_net_names)
    end

    # update existing and create new
    data.each do |net_info|
      if (net = cached.delete(net_info[:name]))
        net.update!(net_info)
      else
        net = Tables::Net.new(net_info)
        AssociateNetWithClub.new(net).call
        net.save!
      end
    end

    # archive closed nets
    cached.values.each do |net|
      Tables::ClosedNet.from_net(net).save!
      net.destroy
    end

    # update all the timestamps at once
    now = Time.now
    Tables::Net.update_all(partially_updated_at: now)
    Tables::Server.update_all(net_list_fetched_at: now)
  end

  def net_cache_needs_updating?
    last_updated = Tables::Server.maximum(:net_list_fetched_at)
    !last_updated || last_updated < Time.now - CACHE_LENGTH_IN_SECONDS
  end

  def fetch
    fetch_nets_in_progress
  end

  def fetch_server_catalog
    Backend.remote.fetch_server_catalog!
  rescue Socket::ResolutionError, Net::OpenTimeout, Net::ReadTimeout, Errno::EHOSTUNREACH => error
    raise ServerError, error.message
  rescue StandardError => error
    raise ParseError, error.message
  end

  def fetch_nets_in_progress
    Backend.remote.fetch_nets_in_progress(servers: Tables::Server.is_public)
  rescue Socket::ResolutionError, Net::OpenTimeout, Net::ReadTimeout, Errno::EHOSTUNREACH => error
    raise ServerError, error.message
  rescue StandardError => error
    raise ParseError, error.message
  end
end
