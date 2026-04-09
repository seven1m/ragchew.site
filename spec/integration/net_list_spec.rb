# frozen_string_literal: true

require 'spec_helper'

RSpec.describe NetList do
  let(:server_list_url) { 'https://www.netlogger.org/downloads/ServerList.txt' }
  let(:base_url) { 'https://www.netlogger.org/cgi-bin/NetLogger' }

  before do
    Tables::BlockedNet.delete_all
    Tables::ClosedNet.delete_all
    Tables::Net.delete_all
    Tables::Server.delete_all
  end

  it 'skips HTTP fetches when server and net caches are fresh' do
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
      name: 'Cached Net',
      frequency: '146.52',
      mode: 'FM',
      band: '2m',
      net_control: 'KI5ZDF',
      net_logger: 'KI5ZDF-TIM R - v3.1.7L',
      im_enabled: true,
      update_interval: 20_000,
      started_at: Time.now
    )

    expect { NetList.new.list }.not_to raise_error
    expect(Tables::Net.where(name: 'Cached Net')).to exist
  end

  it 'parses ServerList/GetServerInfo/GetNetsInProgress and archives closed nets' do
    stub_request(:get, server_list_url).to_return(
      status: 200,
      body: <<~TEXT
        [ServerList]
        www.netlogger.org|NETLOGGER
        www.netlogger4.org|NETLOGGER4
      TEXT
    )

    stub_request(:get, "#{base_url}/GetServerInfo.pl")
      .to_return(
        status: 200,
        body: netlogger_html('<!-- Server Info Start -->CreationDateUTC=Thu 03/05/2026 02:23:44|ServerName=NETLOGGER|ServerHostName=www.netlogger.org|ServerState=Public|MinAIMInterval=30000|DefaultAIMInterval=30000|TokenSupport=True|DeltaUpdates=True|ExtData=True|NetLoggerTimeStampUTCOffset=0|ClubInfoListURL=http://www.netlogger.org/downloads/ClubInfoList.txt|<!-- Server Info End -->')
      )

    stub_request(:get, 'https://www.netlogger4.org/cgi-bin/NetLogger/GetServerInfo.pl')
      .to_return(
        status: 200,
        body: netlogger_html('<!-- Server Info Start -->CreationDateUTC=Thu 03/05/2026 02:23:46|ServerName=NETLOGGER4|ServerHostName=www.netlogger4.org|ServerState=Debug|MinAIMInterval=20000|DefaultAIMInterval=20000|TokenSupport=True|DeltaUpdates=True|ExtData=True|NetLoggerTimeStampUTCOffset=0|ClubInfoListURL=http://www.netlogger.org/downloads/ClubInfoList.txt|<!-- Server Info End -->')
      )

    get_nets_stub = stub_request(:get, "#{base_url}/GetNetsInProgress20.php")
      .with(query: { 'ProtocolVersion' => '2.3' })
      .to_return(
        {
          status: 200,
          body: netlogger_html('<!--NetLogger Start Data-->List Spec Net|146.52|KI5ZDF-TIM R - v3.1.7L|KI5ZDF|20260305022439|FM|2m|Y|20000|List Spec Net||1|~<!--NetLogger End Data-->')
        },
        {
          status: 200,
          body: netlogger_html('<!--NetLogger Start Data--><!--NetLogger End Data-->')
        }
      )

    list = NetList.new.list

    expect(list.map(&:name)).to include('List Spec Net')
    expect(Tables::Server.find_by(host: 'www.netlogger.org')&.is_public).to eq(true)
    expect(Tables::Server.find_by(host: 'www.netlogger4.org')&.is_public).to eq(false)

    NetList.new.update_net_list_right_now_with_wreckless_disregard_for_the_last_update!

    expect(Tables::Net.find_by(name: 'List Spec Net')).to be_nil
    expect(Tables::ClosedNet.where(name: 'List Spec Net')).to exist
    expect(get_nets_stub).to have_been_requested.twice
  end

  it 'filters blocked nets from fetched data' do
    Tables::BlockedNet.create!(name: 'Blocked Net')
    Tables::Server.create!(
      name: 'NETLOGGER',
      host: 'www.netlogger.org',
      state: 'Public',
      is_public: true,
      net_list_fetched_at: 2.minutes.ago,
      updated_at: Time.now
    )

    stub_request(:get, "#{base_url}/GetNetsInProgress20.php")
      .with(query: { 'ProtocolVersion' => '2.3' })
      .to_return(
        status: 200,
        body: netlogger_html('<!--NetLogger Start Data-->Blocked Net|146.52|LOG1|NC1|20260305022439|FM|2m|Y|20000|Blocked Net||1|~Allowed Net|146.55|LOG2|NC2|20260305022439|FM|2m|Y|20000|Allowed Net||1|~<!--NetLogger End Data-->')
      )

    names = NetList.new.list.map(&:name)
    expect(names).to include('Allowed Net')
    expect(names).not_to include('Blocked Net')
  end

  it 'skips nets without start time and notifies Honeybadger' do
    Tables::Server.create!(
      name: 'NETLOGGER',
      host: 'www.netlogger.org',
      state: 'Public',
      is_public: true,
      net_list_fetched_at: 2.minutes.ago,
      updated_at: Time.now
    )

    expect(Honeybadger).to receive(:notify).with('Skipping a net without a start time.', hash_including(:context))

    stub_request(:get, "#{base_url}/GetNetsInProgress20.php")
      .with(query: { 'ProtocolVersion' => '2.3' })
      .to_return(
        status: 200,
        body: netlogger_html('<!--NetLogger Start Data-->No Start|146.52|LOG|NC||FM|2m|Y|20000|No Start||1|~<!--NetLogger End Data-->')
      )

    expect(NetList.new.list.map(&:name)).not_to include('No Start')
  end

  it 'does not create fetched nets with missing required fields' do
    server = Tables::Server.create!(
      name: 'NETLOGGER',
      host: 'www.netlogger.org',
      state: 'Public',
      is_public: true,
      net_list_fetched_at: 2.minutes.ago,
      updated_at: Time.now
    )
    service = NetList.new

    allow(service).to receive(:fetch).and_return([
      {
        name: 'Missing Start',
        frequency: '146.52',
        mode: 'FM',
        net_control: 'NC1',
        net_logger: 'LOG1',
        band: '2m',
        started_at: nil,
        im_enabled: true,
        update_interval: 20_000,
        subscribers: 1,
        server:,
        host: server.host,
      }
    ])
    expect(Honeybadger).to receive(:notify).with(
      'Skipping a fetched net with missing required fields.',
      hash_including(:context)
    )

    expect { service.send(:update_net_cache, force: true) }.not_to raise_error
    expect(Tables::Net.find_by(name: 'Missing Start')).to be_nil
  end

  it 'drops cached nets without start time instead of crashing during archive' do
    server = Tables::Server.create!(
      name: 'NETLOGGER',
      host: 'www.netlogger.org',
      state: 'Public',
      is_public: true,
      net_list_fetched_at: 2.minutes.ago,
      updated_at: Time.now
    )
    invalid_net = Tables::Net.new(
      server:,
      host: server.host,
      name: 'Broken Net',
      frequency: '146.52',
      mode: 'FM',
      band: '2m',
      net_control: 'KI5ZDF',
      net_logger: 'KI5ZDF-TIM R - v3.1.7L',
      im_enabled: true,
      update_interval: 20_000,
      started_at: nil
    )
    invalid_net.save!(validate: false)

    expect(Honeybadger).to receive(:notify).with(
      'Dropping a cached net without a start time before archiving.',
      hash_including(:context)
    )

    stub_request(:get, "#{base_url}/GetNetsInProgress20.php")
      .with(query: { 'ProtocolVersion' => '2.3' })
      .to_return(
        status: 200,
        body: netlogger_html('<!--NetLogger Start Data--><!--NetLogger End Data-->')
      )

    expect { NetList.new.update_net_list_right_now_with_wreckless_disregard_for_the_last_update! }.not_to raise_error
    expect(Tables::Net.find_by(id: invalid_net.id)).to be_nil
    expect(Tables::ClosedNet.where(name: 'Broken Net')).not_to exist
  end

  it 'deletes stale servers that are no longer in ServerList' do
    stale = Tables::Server.create!(
      name: 'STALE',
      host: 'stale.example.org',
      state: 'Public',
      is_public: true,
      net_list_fetched_at: Time.now,
      updated_at: 2.hours.ago
    )

    stub_request(:get, server_list_url).to_return(
      status: 200,
      body: <<~TEXT
        [ServerList]
        www.netlogger.org|NETLOGGER
      TEXT
    )

    stub_request(:get, "#{base_url}/GetServerInfo.pl")
      .to_return(
        status: 200,
        body: netlogger_html('<!-- Server Info Start -->CreationDateUTC=Thu 03/05/2026 02:23:44|ServerName=NETLOGGER|ServerHostName=www.netlogger.org|ServerState=Public|MinAIMInterval=30000|DefaultAIMInterval=30000|TokenSupport=True|DeltaUpdates=True|ExtData=True|NetLoggerTimeStampUTCOffset=0|ClubInfoListURL=http://www.netlogger.org/downloads/ClubInfoList.txt|<!-- Server Info End -->')
      )

    NetList.new.send(:update_server_cache)

    expect(Tables::Server.find_by(id: stale.id)).to be_nil
    expect(Tables::Server.find_by(host: 'www.netlogger.org')).to be_present
  end
end
