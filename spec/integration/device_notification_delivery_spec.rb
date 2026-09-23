# frozen_string_literal: true

require 'spec_helper'
require 'cgi'
require 'uri'

RSpec.describe 'Device notification delivery filters' do
  let(:base_url) { 'https://www.netlogger.org/cgi-bin/NetLogger' }

  before do
    Tables::MessageReaction.delete_all
    Tables::Message.delete_all
    Tables::Monitor.delete_all
    Tables::Checkin.delete_all
    Tables::ClosedNet.delete_all
    Tables::FavoriteNet.delete_all
    Tables::Favorite.delete_all
    Tables::Device.delete_all
    Tables::Net.delete_all
    Tables::Server.delete_all
  end

  it 'skips favorite net notifications when the device disables them' do
    server = Tables::Server.create!(
      name: 'NETLOGGER',
      host: 'www.netlogger.org',
      state: 'Public',
      is_public: true,
      net_list_fetched_at: Time.now,
      updated_at: Time.now
    )
    user = create_user(call_sign: 'K9NET')
    Tables::Device.create!(
      user:,
      token: 'ExponentPushToken[net-off]',
      platform: 'ios',
      favorite_net_notifications: false,
      favorite_station_notifications: true
    )
    Tables::FavoriteNet.create!(user:, net_name: 'Quiet Net')

    expect_any_instance_of(Tables::Device).not_to receive(:send_push_notification)

    Tables::Net.create!(
      server:,
      host: server.host,
      name: 'Quiet Net',
      frequency: '146.52',
      mode: 'FM',
      band: '2m',
      net_control: 'KI5ZDF',
      net_logger: 'KI5ZDF-TIM R - v3.1.7L',
      im_enabled: true,
      started_at: Time.now
    )
  end

  it 'skips favorite station notifications outside awake hours' do
    server = Tables::Server.create!(
      name: 'NETLOGGER',
      host: 'www.netlogger.org',
      state: 'Public',
      is_public: true,
      net_list_fetched_at: Time.now,
      updated_at: Time.now
    )
    net = Tables::Net.create!(
      server:,
      host: server.host,
      name: 'Sleeping Net',
      frequency: '146.52',
      mode: 'FM',
      band: '2m',
      net_control: 'KI5ZDF',
      net_logger: 'KI5ZDF-TIM R - v3.1.7L',
      im_enabled: true,
      started_at: Time.now
    )

    favorite_user = create_user(call_sign: 'K9SLEEP')
    Tables::Device.create!(
      user: favorite_user,
      token: 'ExponentPushToken[sleeping-device]',
      platform: 'ios',
      awake_start_utc_minute: 8 * 60,
      awake_end_utc_minute: 22 * 60,
      favorite_station_notifications: true,
      favorite_net_notifications: true
    )
    Tables::Favorite.create!(user: favorite_user, call_sign: 'KI5NEW')

    expect_any_instance_of(Tables::Device).not_to receive(:send_push_notification)

    allow(Time).to receive(:now).and_return(Time.utc(2026, 3, 5, 3, 0, 0))

    stub_netlogger_xml_updates(checkins: '<Checkin><SerialNo>1</SerialNo><Callsign>KI5NEW</Callsign><FirstName>New Operator</FirstName><CityCountry>Tulsa</CityCountry><State>OK</State><Grid>EM26aa</Grid></Checkin>')

    NetInfo.new(id: net.id).update!
  end
end
