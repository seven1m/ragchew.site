# frozen_string_literal: true

require 'spec_helper'
require 'rake'

extend Rake::DSL
load File.expand_path('../../lib/tasks/canonical_nets.rake', __dir__)

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

  def create_active_net(server:, canonical_net:, name:, club: nil)
    Tables::Net.create!(
      server:,
      canonical_net:,
      club:,
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

  def create_closed_net(canonical_net:, name:, started_at:, club: nil)
    Tables::ClosedNet.create!(
      canonical_net:,
      club:,
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
    Tables::Club.delete_all
    Tables::SuggestedCanonicalNetMerge.delete_all
    Tables::IgnoredCanonicalNetSuggestion.delete_all
    Tables::Server.delete_all
    Tables::User.delete_all
  end

  it 'backfills missing canonical net clubs from active and closed nets' do
    club = Tables::Club.create!(name: 'Metro Club')
    active_canonical = Tables::CanonicalNet.create!(canonical_name: 'Metro Weather Net')
    closed_canonical = Tables::CanonicalNet.create!(canonical_name: 'Metro Traffic Net')
    server = create_server
    Tables::Net.create!(
      server:,
      canonical_net: active_canonical,
      club:,
      host: server.host,
      name: 'Metro Weather Net',
      frequency: '146.52',
      mode: 'FM',
      band: '2m',
      net_control: 'KI5ZDF',
      net_logger: 'KI5ZDF-TIM R - v3.1.7L',
      im_enabled: true,
      update_interval: 20_000,
      started_at: Time.now
    )
    create_closed_net(canonical_net: closed_canonical, name: 'Metro Traffic Net', started_at: 1.day.ago).update!(club:)

    Rake::Task['canonical_nets:backfill'].reenable
    Rake::Task['canonical_nets:backfill'].invoke

    expect(active_canonical.reload.club_id).to eq(club.id)
    expect(closed_canonical.reload.club_id).to eq(club.id)
  end

  it 'renders canonical nets only on the club page and links by canonical name' do
    club = Tables::Club.create!(name: 'Metro Club', about_url: 'https://example.org')
    first = Tables::CanonicalNet.create!(canonical_name: 'Metro Weather Net', club:)
    second = Tables::CanonicalNet.create!(canonical_name: 'Metro Traffic Net', club:)
    create_closed_net(canonical_net: first, name: 'Metro WX', started_at: 1.day.ago, club:)
    create_closed_net(canonical_net: second, name: 'Metro Traffic', started_at: 2.days.ago, club:)

    get "/group/#{CGI.escape(club.name)}"

    expect(last_response.status).to eq(200)
    expect(last_response.body).to include('/net/Metro+Weather+Net')
    expect(last_response.body).to include('/net/Metro+Traffic+Net')
    expect(last_response.body).not_to include('Metro WX')
    expect(last_response.body).not_to include('/net/Metro+Traffic"')
  end

  it 'renders canonical nets on the admin club edit page and hides individual alias names' do
    admin = create_user(call_sign: 'K1ADMIN')
    admin.update!(admin: true)
    club = Tables::Club.create!(name: 'Metro Club')
    canonical_net = Tables::CanonicalNet.create!(canonical_name: 'Metro Weather Net', club:)
    create_closed_net(canonical_net:, name: 'Metro WX', started_at: 1.day.ago, club:)

    get "/admin/clubs/#{club.id}/edit", {}, session_env_for(admin)

    expect(last_response.status).to eq(200)
    expect(last_response.body).to include("/admin/canonical-nets/#{canonical_net.id}")
    expect(last_response.body).to include('Metro Weather Net')
    expect(last_response.body).not_to include('Metro WX')
    expect(last_response.body).to include('Add net')
    expect(last_response.body).to include('/api/admin/canonical-nets/search')
    expect(last_response.body).to include("[#{canonical_net.id}]")
  end

  it 'associates an existing canonical net with a club from the admin club edit page' do
    admin = create_user(call_sign: 'K1ADMIN')
    admin.update!(admin: true)
    club = Tables::Club.create!(name: 'Metro Club')
    canonical_net = Tables::CanonicalNet.create!(canonical_name: 'Metro Weather Net')

    post "/admin/clubs/#{club.id}/canonical-nets", { canonical_net_id: canonical_net.id }, session_env_for(admin)

    expect(last_response.status).to eq(302)
    expect(last_response.headers['Location']).to eq("http://example.org/admin/clubs/#{club.id}/edit")
    expect(canonical_net.reload.club_id).to eq(club.id)
  end

  it 'excludes already-associated canonical nets from admin canonical net search' do
    admin = create_user(call_sign: 'K1ADMIN')
    admin.update!(admin: true)
    excluded = Tables::CanonicalNet.create!(canonical_name: 'Metro Weather Net')
    included = Tables::CanonicalNet.create!(canonical_name: 'Metro Traffic Net')

    get '/api/admin/canonical-nets/search', { q: 'Metro', exclude_ids: excluded.id.to_s }, session_env_for(admin)

    expect(last_response.status).to eq(200)
    expect(last_response.body).not_to include('Metro Weather Net')
    expect(last_response.body).to include('Metro Traffic Net')
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

  it 'supports OR search terms on the canonical admin page' do
    admin = create_user(call_sign: 'K1ADMIN')
    admin.update!(admin: true)
    Tables::CanonicalNet.create!(canonical_name: 'SATERDAY NIGHT 2M SIMPLEX NET')
    Tables::CanonicalNet.create!(canonical_name: 'Saturday Night 2m Simplex Net')
    Tables::CanonicalNet.create!(canonical_name: 'Unrelated Net')

    get '/admin/canonical-nets', { name: 'SATERDAY NIGHT 2M SIMPLEX NET|Saturday Night 2m' }, session_env_for(admin)

    expect(last_response.status).to eq(200)
    expect(last_response.body).to include('SATERDAY NIGHT 2M SIMPLEX NET')
    expect(last_response.body).to include('Saturday Night 2m Simplex Net')
    expect(last_response.body).not_to include('Unrelated Net')
  end

  it 'returns canonical net search suggestions for the admin detail page' do
    admin = create_user(call_sign: 'K1ADMIN')
    admin.update!(admin: true)
    target = Tables::CanonicalNet.create!(canonical_name: 'Saturday Night 2M Simplex Net')
    other = Tables::CanonicalNet.create!(canonical_name: 'SATERDAY NIGHT 2M SIMPLEX NET')
    create_closed_net(canonical_net: other, name: 'SATERDAY NIGHT 2M SIMPLEX NET', started_at: 1.day.ago)

    get '/api/admin/canonical-nets/search', { q: 'SATERDAY', exclude_id: target.id }, session_env_for(admin)

    expect(last_response.status).to eq(200)
    expect(JSON.parse(last_response.body)).to eq([
      {
        'id' => other.id,
        'canonical_name' => 'SATERDAY NIGHT 2M SIMPLEX NET',
        'aliases' => [],
        'active_count' => 0,
        'closed_count' => 1
      }
    ])
  end

  it 'renders canonical net merge search controls on the admin detail page' do
    admin = create_user(call_sign: 'K1ADMIN')
    admin.update!(admin: true)
    canonical_net = Tables::CanonicalNet.create!(canonical_name: 'Saturday Night 2M Simplex Net')

    get "/admin/canonical-nets/#{canonical_net.id}", {}, session_env_for(admin)

    expect(last_response.status).to eq(200)
    expect(last_response.body).to include('Search canonical nets:')
    expect(last_response.body).to include('/api/admin/canonical-nets/search')
    expect(last_response.body).to include('Merge Into This Canonical Net')
  end

  it 'shows the canonical admin link on closed net pages for admins' do
    admin = create_user(call_sign: 'K1ADMIN')
    admin.update!(admin: true)
    canonical_net = Tables::CanonicalNet.create!(canonical_name: 'Saturday Night 2M Simplex Net')
    closed_net = create_closed_net(canonical_net:, name: 'SATERDAY NIGHT 2M SIMPLEX NET', started_at: 1.day.ago)

    get "/closed-net/#{closed_net.id}", {}, session_env_for(admin)

    expect(last_response.status).to eq(200)
    expect(last_response.body).to include("/admin/canonical-nets?name=#{CGI.escape(canonical_net.canonical_name)}")
    expect(last_response.body).to include('canonical admin page')
  end

  it 'shows the canonical admin link on name-based closed net pages for admins' do
    admin = create_user(call_sign: 'K1ADMIN')
    admin.update!(admin: true)
    canonical_net = Tables::CanonicalNet.create!(canonical_name: 'Saturday Night 2M Simplex Net')
    create_closed_net(canonical_net:, name: 'SATERDAY NIGHT 2M SIMPLEX NET', started_at: 1.day.ago)

    get "/net/#{CGI.escape('SATERDAY NIGHT 2M SIMPLEX NET')}", {}, session_env_for(admin)

    expect(last_response.status).to eq(200)
    expect(last_response.body).to include("/admin/canonical-nets?name=#{CGI.escape(canonical_net.canonical_name)}")
    expect(last_response.body).to include('canonical admin page')
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

  it 'merges into an existing canonical net when the requested canonical name already exists' do
    admin = create_user(call_sign: 'K1ADMIN')
    admin.update!(admin: true)
    existing_target = Tables::CanonicalNet.create!(canonical_name: 'YL SYSTEM 17 METER SESSION')
    first = Tables::CanonicalNet.create!(canonical_name: 'YL SYS 17M SESSION')
    second = Tables::CanonicalNet.create!(canonical_name: 'YL System 17 Meter Sess')

    post '/admin/canonical-nets/merge',
         { canonical_net_ids: [first.id, second.id], canonical_name: existing_target.canonical_name },
         session_env_for(admin)

    expect(last_response.status).to eq(302)
    expect(Tables::CanonicalNet.exists?(first.id)).to eq(false)
    expect(Tables::CanonicalNet.exists?(second.id)).to eq(false)
    expect(Tables::CanonicalNet.exists?(existing_target.id)).to eq(true)
  end
end
