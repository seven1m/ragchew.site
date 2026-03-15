# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Tables::CanonicalNet do
  def create_server
    Tables::Server.create!(
      name: 'NETLOGGER',
      host: 'www.netlogger.org',
      state: 'Public',
      is_public: true,
      net_list_fetched_at: Time.now,
      updated_at: Time.now
    )
  end

  def create_active_net(server:, canonical_net:, name:)
    Tables::Net.create!(
      server:,
      canonical_net:,
      host: server.host,
      name:,
      frequency: '146.52',
      mode: 'FM',
      band: '2m',
      net_control: 'KI5ZDF',
      net_logger: 'KI5ZDF-TIM R - v3.1.7L',
      im_enabled: true,
      update_interval: 20_000,
      started_at: Time.now
    )
  end

  def create_closed_net(canonical_net:, name:, started_at:)
    Tables::ClosedNet.create!(
      canonical_net:,
      name:,
      frequency: '146.52',
      mode: 'FM',
      net_control: 'KI5ZDF',
      net_logger: 'KI5ZDF-TIM R - v3.1.7L',
      band: '2m',
      started_at:,
      ended_at: started_at + 1.hour,
      host: 'www.netlogger.org',
      checkin_count: 0,
      message_count: 0,
      monitor_count: 0
    )
  end

  before do
    Tables::FavoriteNet.delete_all
    Tables::ClosedNet.delete_all
    Tables::Net.delete_all
    Tables::CanonicalNet.delete_all
    Tables::Server.delete_all
    Tables::User.delete_all
  end

  it 'merges other groups and deduplicates favorites per user' do
    server = create_server
    target = Tables::CanonicalNet.create!(canonical_name: 'Morning Traffic Net')
    source = Tables::CanonicalNet.create!(canonical_name: 'Morning Traffic Net Alt')
    create_active_net(server:, canonical_net: source, name: 'Morning Traffic Net Alt')
    closed_net = create_closed_net(canonical_net: source, name: 'Morning Traffic Net Alt', started_at: 1.day.ago)
    same_user = create_user(call_sign: 'K1AAA')
    other_user = create_user(call_sign: 'K1BBB')
    Tables::FavoriteNet.create!(user: same_user, canonical_net: target)
    duplicate = Tables::FavoriteNet.create!(user: same_user, canonical_net: source)
    migrated = Tables::FavoriteNet.create!(user: other_user, canonical_net: source)

    target.merge!(other_groups: [source], canonical_name: 'Merged Morning Net')

    expect(target.reload.canonical_name).to eq('Merged Morning Net')
    expect(Tables::CanonicalNet.exists?(source.id)).to eq(false)
    expect(Tables::Net.find_by!(name: 'Morning Traffic Net Alt').canonical_net_id).to eq(target.id)
    expect(closed_net.reload.canonical_net_id).to eq(target.id)
    expect(Tables::FavoriteNet.where(user: same_user, canonical_net: target).count).to eq(1)
    expect(Tables::FavoriteNet.exists?(duplicate.id)).to eq(false)
    expect(migrated.reload.canonical_net_id).to eq(target.id)
    expect(migrated.reload.net_name).to eq('Merged Morning Net')
  end

  it 'splits an alias into its own canonical net' do
    server = create_server
    canonical_net = Tables::CanonicalNet.create!(canonical_name: 'Metro Weather Net')
    aliased_net = create_active_net(server:, canonical_net:, name: 'Metro WX')
    closed_alias = create_closed_net(canonical_net:, name: 'Metro WX', started_at: 1.day.ago)
    primary_net = create_active_net(server:, canonical_net:, name: 'Metro Weather Net')

    split = canonical_net.split_out_alias!(alias_name: 'Metro WX')

    expect(split.canonical_name).to eq('Metro WX')
    expect(aliased_net.reload.canonical_net_id).to eq(split.id)
    expect(closed_alias.reload.canonical_net_id).to eq(split.id)
    expect(primary_net.reload.canonical_net_id).to eq(canonical_net.id)
  end

  it 'deletes a canonical net by splitting its aliases into new groups' do
    server = create_server
    canonical_net = Tables::CanonicalNet.create!(canonical_name: 'Regional Group')
    alpha = create_active_net(server:, canonical_net:, name: 'Alpha Net')
    beta = create_closed_net(canonical_net:, name: 'Beta Net', started_at: 1.day.ago)

    canonical_net.destroy_with_splits!

    expect(Tables::CanonicalNet.exists?(canonical_net.id)).to eq(false)
    expect(alpha.reload.canonical_net.canonical_name).to eq('Alpha Net')
    expect(beta.reload.canonical_net.canonical_name).to eq('Beta Net')
  end
end
