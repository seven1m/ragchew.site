# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CanonicalNetResolver do
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

  def create_active_net(server:, canonical_net:, name:, started_at: Time.now, frequency: '146.52', band: '2m')
    Tables::Net.create!(
      server:,
      canonical_net:,
      host: server.host,
      name:,
      frequency:,
      mode: 'FM',
      band:,
      net_control: 'KI5ZDF',
      net_logger: 'KI5ZDF-TIM R - v3.1.7L',
      im_enabled: true,
      update_interval: 20_000,
      started_at:
    )
  end

  def create_closed_net(canonical_net:, name:, started_at:, ended_at: started_at + 1.hour, frequency: '146.52', band: '2m')
    Tables::ClosedNet.create!(
      canonical_net:,
      name:,
      frequency:,
      mode: 'FM',
      net_control: 'KI5ZDF',
      net_logger: 'KI5ZDF-TIM R - v3.1.7L',
      band:,
      started_at:,
      ended_at:,
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
    Tables::IgnoredCanonicalNetSuggestion.delete_all
    Tables::SuggestedCanonicalNetMerge.delete_all
    Tables::Server.delete_all
  end

  describe '.resolve' do
    it 'resolves by canonical name, active alias, and closed alias' do
      server = create_server
      canonical_net = Tables::CanonicalNet.create!(canonical_name: 'Metro Weather Net')
      create_active_net(server:, canonical_net:, name: 'Metro WX')

      expect(described_class.resolve('Metro Weather Net')).to eq(canonical_net)
      expect(described_class.resolve('Metro WX')).to eq(canonical_net)

      Tables::Net.delete_all
      closed_net = create_closed_net(canonical_net:, name: 'Metro WX', started_at: 1.day.ago)

      expect(described_class.resolve('Metro WX')).to eq(canonical_net)
      expect(closed_net.canonical_net).to eq(canonical_net)
    end
  end

  describe '.representative_for' do
    it 'prefers an active net over a closed net' do
      server = create_server
      canonical_net = Tables::CanonicalNet.create!(canonical_name: 'Metro Weather Net')
      active_net = create_active_net(server:, canonical_net:, name: 'Metro WX')
      create_closed_net(canonical_net:, name: 'Metro Weather Net', started_at: 1.day.ago)

      expect(described_class.representative_for(canonical_net)).to eq(type: :active, record: active_net)
    end

    it 'falls back to the newest closed net when no active net exists' do
      canonical_net = Tables::CanonicalNet.create!(canonical_name: 'Metro Weather Net')
      older = create_closed_net(canonical_net:, name: 'Metro WX', started_at: 3.days.ago)
      newer = create_closed_net(canonical_net:, name: 'Metro Weather Net', started_at: 1.day.ago)

      expect(described_class.representative_for(canonical_net)).to eq(type: :closed, record: newer)
      expect(older).not_to eq(newer)
    end
  end

  describe '.computed_suggestions' do
    it 'suggests merges for similar names on the same frequency and band' do
      server = create_server
      first = Tables::CanonicalNet.create!(canonical_name: 'Mid Counties Traffic Net')
      second = Tables::CanonicalNet.create!(canonical_name: 'Mid Counties Traffic Net Late')
      create_active_net(server:, canonical_net: first, name: first.canonical_name, frequency: '146.88', band: '2m')
      create_active_net(server:, canonical_net: second, name: second.canonical_name, frequency: '146.88', band: '2m')

      suggestions = described_class.computed_suggestions

      expect(suggestions.size).to eq(1)
      expect(suggestions.first.canonical_nets.map(&:canonical_name)).to eq(
        ['Mid Counties Traffic Net', 'Mid Counties Traffic Net Late']
      )
      expect(suggestions.first.raw_names).to include('Mid Counties Traffic Net', 'Mid Counties Traffic Net Late')
    end
  end
end
