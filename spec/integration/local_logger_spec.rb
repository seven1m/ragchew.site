# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'LocalLogger' do
  before do
    Tables::MessageReaction.delete_all
    Tables::Message.delete_all
    Tables::Monitor.delete_all
    Tables::Checkin.delete_all
    Tables::ClosedNet.delete_all
    Tables::Net.delete_all
    Tables::Server.delete_all
  end

  it 'creates, updates, chats, blocks, and closes a local testing net without external HTTP' do
    user = create_user(call_sign: 'KI5ZDF', first_name: 'TIM R', last_name: 'MORGAN')
    user.admin = true
    user.save!
    headers = auth_headers_for(user)

    post '/api/create-net', {
      club_id: 'no_club',
      net_name: 'Local Testing Net',
      net_password: 'ecg',
      frequency: '146.52',
      band: '2m',
      mode: 'FM',
      net_control: 'KI5ZDF',
      ragchew_only_testing_net: true,
      blocked_stations: []
    }.to_json, headers.merge('CONTENT_TYPE' => 'application/json')

    expect(last_response.status).to eq(302)

    net = Tables::Net.find_by!(name: 'Local Testing Net')
    expect(net.ragchew_only_testing_net?).to eq(true)
    expect(user.reload.monitoring_net_id).to eq(net.id)

    patch "/api/log/#{net.id}/1", {
      num: 1,
      call_sign: 'KI5ZDF',
      city: 'Tulsa',
      state: 'OK',
      name: 'Tim R Morgan',
      preferred_name: 'Tim',
      notes: 'first pass'
    }.to_json, headers.merge('CONTENT_TYPE' => 'application/json')
    expect(last_response.status).to eq(200)

    # Extra request params like expires_at should be ignored by the local backend.
    patch "/api/log/#{net.id}/1", {
      num: 1,
      call_sign: 'KI5ZDF',
      city: 'Tulsa',
      state: 'OK',
      name: 'Timothy Morgan',
      preferred_name: 'Tim',
      notes: 'updated',
      expires_at: 1.hour.from_now.iso8601
    }.to_json, headers.merge('CONTENT_TYPE' => 'application/json')
    expect(last_response.status).to eq(200)

    post "/api/message/#{net.id}", { message: 'hello local world' }, headers
    expect(last_response.status).to eq(201)

    post "/api/net/#{net.id}/blocked-stations/KI5ZDG", {}, headers
    expect(last_response.status).to eq(200)

    expect(net.reload.checkins.pluck(:call_sign, :name, :notes)).to eq([['KI5ZDF', 'Timothy Morgan', 'updated']])
    expect(Tables::Message.where(net_id: net.id).pluck(:message)).to include('hello local world')
    expect(net.blocked_stations.where(call_sign: 'KI5ZDG')).to exist

    post "/close-net/#{net.id}", {}, headers
    expect(last_response.status).to eq(302)

    expect(Tables::Net.find_by(id: net.id)).to be_nil
    expect(Tables::ClosedNet.where(name: 'Local Testing Net')).to exist
    expect(WebMock).not_to have_requested(:any, %r{netlogger\.org|/cgi-bin/NetLogger/})
  end

  it 'tracks monitor records for a local testing net' do
    admin = create_user(call_sign: 'KI5ZDF', first_name: 'TIM R', last_name: 'MORGAN')
    admin.admin = true
    admin.save!
    admin_headers = auth_headers_for(admin)

    post '/api/create-net', {
      club_id: 'no_club',
      net_name: 'Local Monitor Net',
      net_password: 'ecg',
      frequency: '146.52',
      band: '2m',
      mode: 'FM',
      net_control: 'KI5ZDF',
      ragchew_only_testing_net: true,
      blocked_stations: []
    }.to_json, admin_headers.merge('CONTENT_TYPE' => 'application/json')

    expect(last_response.status).to eq(302)

    net = Tables::Net.find_by!(name: 'Local Monitor Net')
    user = create_user(call_sign: 'KI5ABC', first_name: 'TEST', last_name: 'USER')
    headers = auth_headers_for(user)

    post "/api/monitor/#{net.id}", {}, headers

    expect(last_response.status).to eq(200)

    monitor = net.monitors.find_by(call_sign: 'KI5ABC')

    expect(monitor).not_to be_nil
    expect(monitor.name).to eq('TEST')
    expect(monitor.version).to eq(UserPresenter::NET_LOGGER_FAKE_VERSION)
    expect(user.reload.monitoring_net_id).to eq(net.id)

    post "/api/unmonitor/#{net.id}", {}, headers

    expect(last_response.status).to eq(200)
    expect(net.reload.monitors.find_by(call_sign: 'KI5ABC')).to be_nil
    expect(user.reload.monitoring_net_id).to be_nil
  end

  it 'stores echolink from the starting frequency and preserves it when closing' do
    user = create_user(call_sign: 'KI5ZDF', first_name: 'TIM R', last_name: 'MORGAN')
    user.admin = true
    user.save!
    headers = auth_headers_for(user)

    post '/api/create-net', {
      club_id: 'no_club',
      net_name: 'Local EchoLink Net',
      net_password: 'ecg',
      frequency: 'EchoLink 1002775',
      band: '2m',
      mode: 'FM',
      net_control: 'KI5ZDF',
      ragchew_only_testing_net: true,
      blocked_stations: []
    }.to_json, headers.merge('CONTENT_TYPE' => 'application/json')

    expect(last_response.status).to eq(302)

    net = Tables::Net.find_by!(name: 'Local EchoLink Net')
    expect(net.echolink).to eq(
      'node' => '1002775',
      'source' => 'frequency'
    )

    get "/api/net/#{net.id}/details", {}, headers
    expect(last_response.status).to eq(200)
    expect(JSON.parse(last_response.body).dig('net', 'echolink')).to eq(
      'node' => '1002775',
      'source' => 'frequency'
    )

    post "/close-net/#{net.id}", {}, headers
    expect(last_response.status).to eq(302)

    closed_net = Tables::ClosedNet.find_by!(name: 'Local EchoLink Net')
    expect(closed_net.echolink).to eq(
      'node' => '1002775',
      'source' => 'frequency'
    )
  end
end
