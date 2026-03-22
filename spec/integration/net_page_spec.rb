# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'net page' do
  before do
    Tables::MessageReaction.delete_all
    Tables::Message.delete_all
    Tables::Monitor.delete_all
    Tables::Checkin.delete_all
    Tables::ClosedNet.delete_all
    Tables::Net.delete_all
    Tables::FavoriteNet.delete_all
    Tables::CanonicalNet.delete_all
    Tables::Server.delete_all
  end

  def create_local_net(name:, canonical_name:)
    canonical_net = Tables::CanonicalNet.create!(canonical_name:)
    net = Tables::Net.create!(
      host: 'ragchew.site',
      name:,
      frequency: '146.52',
      mode: 'FM',
      band: '2m',
      net_control: 'K1NET',
      net_logger: 'K1NET-TEST - v1.0',
      im_enabled: true,
      update_interval: 20_000,
      started_at: Time.now,
      created_by_ragchew: true,
      ragchew_only_testing_net: true,
      canonical_net:
    )

    [net, canonical_net]
  end

  it 'shows an admin-only link to the canonical merge page' do
    net, canonical_net = create_local_net(
      name: 'SATERDAY NIGHT 2M SIMPLEX NET',
      canonical_name: 'Saturday Night 2M Simplex Net'
    )

    admin = create_user(call_sign: 'K1ADMIN')
    admin.update!(admin: true)

    get "/net/#{CGI.escape(net.name)}", {}, auth_headers_for(admin)

    expect(last_response.status).to eq(200)
    expect(last_response.body).to include("/admin/canonical-nets?name=#{CGI.escape(canonical_net.canonical_name)}")
    expect(last_response.body).to include('view canonical admin page')
  end

  it 'does not show the canonical merge link to non-admins' do
    net, = create_local_net(
      name: 'SATERDAY NIGHT 2M SIMPLEX NET',
      canonical_name: 'Saturday Night 2M Simplex Net'
    )

    user = create_user(call_sign: 'K1USER')

    get "/net/#{CGI.escape(net.name)}", {}, auth_headers_for(user)

    expect(last_response.status).to eq(200)
    expect(last_response.body).not_to include('/admin/canonical-nets?name=')
    expect(last_response.body).not_to include('view canonical admin page')
  end
end
