# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'canonical nets' do
  def session_env_for(user)
    { 'rack.session' => { user_id: user.id } }
  end

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
    Tables::SuggestedCanonicalNetMerge.delete_all
    Tables::IgnoredCanonicalNetSuggestion.delete_all
    Tables::Server.delete_all
    Tables::User.delete_all
  end

  it 'renders the public canonical page with the canonical title and alias label' do
    server = create_server
    canonical_net = Tables::CanonicalNet.create!(canonical_name: 'Metro Weather Net')
    create_active_net(server:, canonical_net:, name: 'Metro WX')

    get "/nets/#{canonical_net.id}"

    expect(last_response.status).to eq(200)
    expect(last_response.body).to include('Metro Weather Net')
    expect(last_response.body).to include('Logged as Metro WX')
  end

  it 'returns closed canonical net metadata from api/net_id for an alias' do
    canonical_net = Tables::CanonicalNet.create!(canonical_name: 'Metro Weather Net')
    closed_net = create_closed_net(canonical_net:, name: 'Metro WX', started_at: 1.day.ago)

    get "/api/net_id/#{CGI.escape('Metro WX')}"

    expect(last_response.status).to eq(404)
    expect(JSON.parse(last_response.body)).to eq(
      'error' => 'net closed',
      'closedNetId' => closed_net.id,
      'canonicalNetId' => canonical_net.id
    )
  end

  it 'favorites a canonical net by name and unfavorites it by id' do
    user = create_user(call_sign: 'K1ABC')
    canonical_net = Tables::CanonicalNet.create!(canonical_name: 'Metro Weather Net')

    post "/api/favorite_net/#{CGI.escape(canonical_net.canonical_name)}", {}, auth_headers_for(user)

    expect(last_response.status).to eq(200)
    expect(JSON.parse(last_response.body)).to eq('favorited' => true)
    expect(user.favorite_nets.find_by!(canonical_net_id: canonical_net.id).net_name).to eq('Metro Weather Net')

    post "/api/unfavorite_net/#{canonical_net.id}", {}, auth_headers_for(user)

    expect(last_response.status).to eq(200)
    expect(JSON.parse(last_response.body)).to eq('favorited' => false)
    expect(user.favorite_nets.where(canonical_net_id: canonical_net.id)).to be_empty
  end

  it 'merges canonical nets through the admin route' do
    admin = create_user(call_sign: 'K1ADMIN')
    admin.update!(admin: true)
    target = Tables::CanonicalNet.create!(canonical_name: 'Metro Weather Net')
    source = Tables::CanonicalNet.create!(canonical_name: 'Metro WX')
    user = create_user(call_sign: 'K1FAVE')
    favorite = Tables::FavoriteNet.create!(user:, canonical_net: source)

    post '/admin/canonical-nets/merge',
         { canonical_net_ids: [target.id, source.id], canonical_name: 'Merged Metro Net' },
         session_env_for(admin)

    expect(last_response.status).to eq(302)
    expect(last_response.headers['Location']).to eq('http://example.org/admin/canonical-nets?name=Merged+Metro+Net')
    expect(target.reload.canonical_name).to eq('Merged Metro Net')
    expect(Tables::CanonicalNet.exists?(source.id)).to eq(false)
    expect(favorite.reload.canonical_net_id).to eq(target.id)
    expect(favorite.reload.net_name).to eq('Merged Metro Net')
  end
end
