# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'test user netlogger guard' do
  let(:base_url) { 'https://www.netlogger.org/cgi-bin/NetLogger' }

  before do
    Tables::MessageReaction.delete_all
    Tables::Message.delete_all
    Tables::Monitor.delete_all
    Tables::Checkin.delete_all
    Tables::ClosedNet.delete_all
    Tables::Net.delete_all
    Tables::Server.delete_all
  end

  def create_test_user(call_sign: 'X0REV')
    user = create_user(call_sign:, first_name: 'Review', last_name: 'Demo')
    user.test_user = true
    user.save!
    user
  end

  def create_remote_net(name: 'Guarded Net')
    server = Tables::Server.create!(
      name: 'NETLOGGER',
      host: 'www.netlogger.org',
      state: 'Public',
      is_public: true,
      net_list_fetched_at: Time.now,
      updated_at: Time.now
    )

    Tables::Net.create!(
      server:,
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

  it 'does not treat test users as net loggers' do
    user = create_test_user

    expect(user.net_logger?).to eq(false)
  end

  it 'blocks test users from monitoring and messaging remote nets without outbound requests' do
    user = create_test_user
    net = create_remote_net
    headers = auth_headers_for(user)

    post "/api/monitor/#{net.id}", {}, headers

    expect(last_response.status).to eq(401)
    expect(last_response.body).to include('not authorized')
    expect(user.reload.monitoring_net_id).to be_nil

    user.update!(monitoring_net: net)

    post "/api/message/#{net.id}", { message: 'hello world' }, headers

    expect(last_response.status).to eq(401)
    expect(last_response.body).to include('Test users cannot mutate NetLogger servers.')
    expect(Tables::Message.where(net_id: net.id)).to be_empty
    expect(WebMock).not_to have_requested(:any, %r{#{Regexp.escape(base_url)}})
  end

  it 'blocks direct NetLogger create and start_logging calls for test users before any outbound request' do
    user = create_test_user
    net = create_remote_net(name: 'Started Elsewhere')

    expect do
      Backend::NetLogger.create_net!(
        club: nil,
        name: 'Should Not Open',
        password: 'secret',
        frequency: '146.52',
        net_control: 'X0REV',
        user:,
        mode: 'FM',
        band: '2m',
        blocked_stations: []
      )
    end.to raise_error(Backend::NetLogger::NotAuthorizedError, 'Test users cannot mutate NetLogger servers.')

    expect do
      Backend::NetLogger.start_logging(NetInfo.new(id: net.id), password: 'secret', user:)
    end.to raise_error(Backend::NetLogger::NotAuthorizedError, 'Test users cannot mutate NetLogger servers.')

    expect(WebMock).not_to have_requested(:any, %r{#{Regexp.escape(base_url)}})
  end
end
