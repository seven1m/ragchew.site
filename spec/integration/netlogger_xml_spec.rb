# frozen_string_literal: true

require "spec_helper"

RSpec.describe "NetLogger XML integration" do
  let(:base_url) { "https://www.netlogger.org/api" }

  def xml(body)
    <<~XML
      <?xml version="1.0" encoding="ISO-8859-1"?>
      <NetLoggerXML>
        <Header><CreationDateUTC>Tue 09/22/2026 17:36:38</CreationDateUTC><TimeZone>UTC</TimeZone></Header>
        #{body}
      </NetLoggerXML>
    XML
  end

  def active_xml(nets)
    xml(
      "<ServerList><ResponseCode>200 OK</ResponseCode><Server><ServerName>NETLOGGER</ServerName>#{nets}</Server><Server><ServerName>NETLOGGER3</ServerName></Server></ServerList>"
    )
  end

  def net_xml(name)
    "<Net><NetName>#{name}</NetName><AltNetName>#{name}</AltNetName><Frequency>146.52</Frequency><Logger>K1ABC-TEST</Logger><NetControl>K1ABC</NetControl><Date>2026-09-22 17:00:00</Date><Mode>FM</Mode><Band>2m</Band><SubscriberCount>2</SubscriberCount><FutureField>ignored</FutureField></Net>"
  end

  def remote_net(name: "XML Net")
    server =
      Tables::Server.find_or_create_by!(name: "NETLOGGER") do |record|
        record.host = "www.netlogger.org"
        record.is_public = true
      end
    Tables::Net.create!(
      server:,
      host: server.host,
      name:,
      started_at: Time.utc(2026, 9, 22, 17),
      frequency: "146.52"
    )
  end

  before do
    Tables::MessageReaction.delete_all
    Tables::Message.delete_all
    Tables::Monitor.delete_all
    Tables::Checkin.delete_all
    Tables::ClosedNet.delete_all
    Tables::Net.delete_all
    Tables::Server.delete_all
  end

  it "discovers external nets by server and name while leaving local nets alone" do
    local =
      Tables::Net.create!(
        name: "Local Net",
        host: "ragchew.site",
        started_at: Time.now
      )
    stub_request(:get, "#{base_url}/GetActiveNets.php").to_return(
      { status: 200, body: active_xml(net_xml("XML Net")) },
      { status: 200, body: active_xml("") }
    )

    NetList.new.list
    expect(WebMock).to have_requested(
      :get,
      "#{base_url}/GetActiveNets.php"
    ).with(headers: { "User-Agent" => NetloggerXML::USER_AGENT })
    remote = Tables::Net.find_by!(name: "XML Net")
    expect(local.local_net?).to eq(true)
    expect(remote.local_net?).to eq(false)
    expect(remote.server.name).to eq("NETLOGGER")
    expect(remote.as_json["source"]).to eq("netlogger")
    expect(Tables::Server.find_by!(name: "NETLOGGER3").host).to eq(
      "www.netlogger3.org"
    )

    NetList.new.update_net_list_right_now_with_wreckless_disregard_for_the_last_update!
    expect(Tables::Net.find_by(id: remote.id)).to be_nil
    expect(Tables::ClosedNet.find_by!(name: "XML Net").local_net?).to eq(false)
    expect(Tables::Net.find_by(id: local.id)).to be_present
    expect(Tables::ClosedNet.from_net(local).local_net?).to eq(true)
  end

  it "keeps cached nets after invalid XML or rate limiting" do
    remote = remote_net
    stub_request(:get, "#{base_url}/GetActiveNets.php").to_return(
      status: 200,
      body: "<broken"
    )
    NetList.new.update_net_list_right_now_with_wreckless_disregard_for_the_last_update!
    expect(Tables::Net.find_by(id: remote.id)).to be_present

    stub_request(:get, "#{base_url}/GetActiveNets.php").to_return(
      status: 200,
      body: xml("<ResponseCode>429 Too Many Requests</ResponseCode>")
    )
    NetList.new.update_net_list_right_now_with_wreckless_disregard_for_the_last_update!
    expect(Tables::Net.find_by(id: remote.id)).to be_present
  end

  it "accepts documented top-level empty results without abandoning the net refresh" do
    net = remote_net
    stub_request(
      :get,
      %r{#{Regexp.escape(base_url)}/GetCheckins\.php}
    ).to_return(
      status: 200,
      body:
        xml(
          "<CheckinList><ResponseCode>200 OK</ResponseCode><Pointer>0</Pointer><Checkin><SerialNo>1</SerialNo><Callsign>K1ABC</Callsign></Checkin></CheckinList>"
        )
    )
    empty_result =
      xml(
        "<Error>Query returned an empty result</Error><ResponseCode>404 Not Found</ResponseCode>"
      )
    stub_request(:get, %r{#{Regexp.escape(base_url)}/GetAIM\.php}).to_return(
      status: 200,
      body: empty_result
    )
    stub_request(
      :get,
      %r{#{Regexp.escape(base_url)}/GetMonitors\.php}
    ).to_return(status: 200, body: empty_result)

    NetInfo.new(id: net.id).update!

    expect(net.checkins.pluck(:call_sign)).to eq(["K1ABC"])
    expect(net.messages.count).to eq(0)
    expect(net.reload.aim_next_request_id).to eq(-100)
    expect(net.fully_updated_at).not_to be_nil
  end

  it "does not confuse an invalid server with an empty result" do
    stub_request(:get, "#{base_url}/GetAIM.php").to_return(
      status: 200,
      body:
        xml(
          "<Error>Not a valid ServerName</Error><ResponseCode>404 Not Found</ResponseCode>"
        )
    )

    expect { NetloggerXML.new.get("GetAIM.php", empty: true) }.to raise_error(
      NetloggerXML::NotFound
    )
  end

  it "requests and caches a session key with the API key as a query parameter" do
    REDIS.del(NetloggerXML::SESSION_CACHE_KEY)
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("NETLOGGER_API_KEY").and_return(
      "test-api-key"
    )
    session =
      stub_request(:get, "#{base_url}/GetNewAPISessionKey.php").with(
        query: {
          "APIKey" => "test-api-key"
        },
        headers: {
          "User-Agent" => NetloggerXML::USER_AGENT
        }
      ).to_return(
        status: 200,
        body:
          xml(
            "<Session><ResponseCode>200 OK</ResponseCode><SessionKey>test-session-key</SessionKey></Session>"
          )
      )

    client = NetloggerXML.new
    expect(client.session_key).to eq("test-session-key")
    expect(client.session_key).to eq("test-session-key")
    expect(session).to have_been_requested.once
  end

  it "defers chat and monitors during populate but fetches them on the next visit" do
    net = remote_net
    stub_request(
      :get,
      %r{#{Regexp.escape(base_url)}/GetCheckins\.php}
    ).to_return(
      status: 200,
      body:
        xml(
          "<CheckinList><ResponseCode>200 OK</ResponseCode><Pointer>0</Pointer><Checkin><SerialNo>1</SerialNo><Callsign>K1ABC</Callsign></Checkin></CheckinList>"
        )
    )
    aim =
      stub_request(:get, %r{#{Regexp.escape(base_url)}/GetAIM\.php}).to_return(
        status: 200,
        body:
          xml(
            "<AIMTranscript><ResponseCode>200 OK</ResponseCode><AIMNextRequestID>123</AIMNextRequestID><AIMEntry><id>123</id><Callsign>K1ABC-ALEX</Callsign><Message>hello</Message><aim_time>2026-09-22 17:36:30</aim_time></AIMEntry></AIMTranscript>"
          )
      )
    monitors =
      stub_request(
        :get,
        %r{#{Regexp.escape(base_url)}/GetMonitors\.php}
      ).to_return(
        status: 200,
        body:
          xml(
            "<MonitorList><ResponseCode>404 Not Found</ResponseCode></MonitorList>"
          )
      )

    service = NetInfo.new(id: net.id)
    service.update!(include_aim: false, include_monitors: false)
    expect(net.checkins.pluck(:call_sign)).to eq(["K1ABC"])
    expect(net.reload.aim_fetched_at).to be_nil
    expect(net.monitors_fetched_at).to be_nil
    expect(aim).not_to have_been_requested
    expect(monitors).not_to have_been_requested

    service.update!
    expect(aim).to have_been_requested.once
    expect(monitors).to have_been_requested.once
    expect(net.messages.pluck(:message)).to eq(["hello"])
  end

  it "keeps check-ins when the chat feed is rate limited" do
    net = remote_net
    stub_request(
      :get,
      %r{#{Regexp.escape(base_url)}/GetCheckins\.php}
    ).to_return(
      status: 200,
      body:
        xml(
          "<CheckinList><ResponseCode>200 OK</ResponseCode><Pointer>0</Pointer><Checkin><SerialNo>1</SerialNo><Callsign>K1ABC</Callsign></Checkin></CheckinList>"
        )
    )
    stub_request(:get, %r{#{Regexp.escape(base_url)}/GetAIM\.php}).to_return(
      status: 429,
      body: ""
    )
    stub_request(
      :get,
      %r{#{Regexp.escape(base_url)}/GetMonitors\.php}
    ).to_return(
      status: 200,
      body:
        xml(
          "<MonitorList><ResponseCode>404 Not Found</ResponseCode></MonitorList>"
        )
    )

    NetInfo.new(id: net.id).update!

    expect(net.checkins.pluck(:call_sign)).to eq(["K1ABC"])
    expect(net.reload.checkins_fetched_at).not_to be_nil
    expect(net.aim_fetched_at).to be_nil
    expect(net.monitors_fetched_at).not_to be_nil
  end

  it "reconciles check-ins, AIM, and monitors with independent cursors and cadence" do
    net = remote_net
    checkins =
      stub_request(:get, "#{base_url}/GetCheckins.php").with(
        query: {
          "ServerName" => "NETLOGGER",
          "NetName" => "XML Net"
        }
      ).to_return(
        {
          status: 200,
          body:
            xml(
              "<CheckinList><ResponseCode>200 OK</ResponseCode><Pointer>1</Pointer><Checkin><SerialNo>1</SerialNo><Callsign>K1ABC</Callsign><FirstName>Alex</FirstName><Grid>EM26aa</Grid></Checkin></CheckinList>"
            )
        },
        {
          status: 200,
          body:
            xml(
              "<CheckinList><ResponseCode>200 OK</ResponseCode><Pointer>0</Pointer><Checkin><SerialNo>1</SerialNo><Callsign>K1ABC</Callsign><FirstName>Alexander</FirstName><Grid>EM26aa</Grid></Checkin></CheckinList>"
            )
        },
        {
          status: 200,
          body:
            xml(
              "<CheckinList><ResponseCode>404 Not Found</ResponseCode><Pointer>0</Pointer></CheckinList>"
            )
        }
      )
    aim =
      stub_request(:get, %r{#{Regexp.escape(base_url)}/GetAIM\.php}).to_return(
        {
          status: 200,
          body:
            xml(
              "<AIMTranscript><ResponseCode>200 OK</ResponseCode><AIMNextRequestID>123</AIMNextRequestID><AIMEntry><id>123</id><Callsign>K1ABC-ALEX</Callsign><Message>hello</Message><aim_time>2026-09-22 17:36:30</aim_time></AIMEntry></AIMTranscript>"
            )
        },
        {
          status: 200,
          body:
            xml(
              "<AIMTranscript><ResponseCode>404 Not Found</ResponseCode><AIMNextRequestID>123</AIMNextRequestID></AIMTranscript>"
            )
        },
        {
          status: 200,
          body:
            xml(
              "<AIMTranscript><ResponseCode>404 Not Found</ResponseCode><AIMNextRequestID>123</AIMNextRequestID></AIMTranscript>"
            )
        }
      )
    monitors =
      stub_request(
        :get,
        %r{#{Regexp.escape(base_url)}/GetMonitors\.php}
      ).to_return(
        status: 200,
        body:
          xml(
            "<MonitorList><ResponseCode>200 OK</ResponseCode><Monitor><MonitorIndex>3</MonitorIndex><Operator>K1ABC-ALEX</Operator><Version>v1.3A</Version><OfflineStatus>FALSE</OfflineStatus><AIMGroupIgnoreStatus>FALSE</AIMGroupIgnoreStatus></Monitor></MonitorList>"
          )
      )

    service = NetInfo.new(id: net.id)
    service.update!
    checkin = net.checkins.find_by!(num: 1)
    original_time = checkin.checked_in_at
    expect(checkin.currently_operating?).to eq(true)
    expect(net.reload.aim_next_request_id).to eq(123)
    expect(net.messages.pluck(:message)).to eq(["hello"])
    expect(net.monitors.find_by!(call_sign: "K1ABC").num).to eq(3)
    expect(WebMock).to have_requested(
      :get,
      %r{#{Regexp.escape(base_url)}/GetAIM\.php}
    ).with(query: hash_including("id" => "-100"))
    expect(WebMock).to have_requested(
      :get,
      %r{#{Regexp.escape(base_url)}/GetAIM\.php}
    ).with(headers: { "User-Agent" => NetloggerXML::USER_AGENT })
    expect(WebMock).to have_requested(
      :get,
      %r{#{Regexp.escape(base_url)}/GetCheckins\.php}
    ).with(headers: { "User-Agent" => NetloggerXML::USER_AGENT })
    expect(WebMock).to have_requested(
      :get,
      %r{#{Regexp.escape(base_url)}/GetMonitors\.php}
    ).with(headers: { "User-Agent" => NetloggerXML::USER_AGENT })

    net.update_columns(
      checkins_fetched_at: 1.minute.ago,
      aim_fetched_at: 1.minute.ago
    )
    service.update_net_right_now_with_wreckless_disregard_for_the_last_update!
    expect(checkin.reload.name).to eq("Alexander")
    expect(checkin.checked_in_at).to eq(original_time)
    expect(checkin.currently_operating?).to eq(false)
    expect(WebMock).to have_requested(
      :get,
      %r{#{Regexp.escape(base_url)}/GetAIM\.php}
    ).with(query: hash_including("id" => "123"))
    expect(monitors).to have_been_requested.once

    service.update_net_right_now_with_wreckless_disregard_for_the_last_update!(
      force_full: true
    )
    expect(net.checkins.count).to eq(0)
    expect(checkins).to have_been_requested.times(3)
    expect(aim).to have_been_requested.times(3)
  end

  it "rejects external logger operations without an outbound request" do
    net = remote_net
    user = create_user(call_sign: "K1ABC")
    expect {
      NetInfo.start_logging!(id: net.id, password: "x", user:)
    }.to raise_error(Backend::Logger::NotAuthorizedError)
    expect(WebMock).not_to have_requested(:any, /netlogger\.org/)
  end
end
