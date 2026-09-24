require 'spec_helper'

RSpec.describe 'sending messages' do
  before do
    Tables::MessageReaction.delete_all
    Tables::Message.delete_all
    Tables::Monitor.delete_all
    Tables::Checkin.delete_all
    Tables::ClosedNet.delete_all
    Tables::Net.delete_all
    Tables::Server.delete_all
  end

  let(:net) { Tables::Net.create!(name: 'Message Test Net', host: 'ragchew.site', started_at: Time.now) }
  let(:user) do
    create_user(call_sign: 'K1USER', first_name: 'Alex').tap do |record|
      record.update!(monitoring_net: net)
    end
  end

  it 'removes the temporary message when the backend rejects it' do
    backend = double(send_message!: nil)
    allow(Backend::Logger).to receive(:new).and_return(backend)
    allow(backend).to receive(:send_message!).and_raise(Backend::Logger::NotAuthorizedError, 'Not allowed')

    post "/api/message/#{net.id}", { message: 'Hello' }, auth_headers_for(user)

    expect(last_response.status).to eq(401)
    expect(JSON.parse(last_response.body)).to eq('error' => 'Not allowed')
    expect(net.messages.count).to eq(0)
  end

  it 'removes the temporary message when the backend server fails' do
    backend = double(send_message!: nil)
    allow(Backend::Logger).to receive(:new).and_return(backend)
    allow(backend).to receive(:send_message!).and_raise(NetloggerXML::Error, 'Backend failed')

    post "/api/message/#{net.id}", { message: 'Hello' }, auth_headers_for(user)

    expect(last_response.status).to eq(500)
    expect(JSON.parse(last_response.body)).to eq('error' => 'There was an error with the server. Please try again later.')
    expect(net.messages.count).to eq(0)
  end

  it 'reports the NetLogger message cooldown and removes the temporary message' do
    server = Tables::Server.create!(name: 'NETLOGGER', host: 'www.netlogger.org', is_public: true)
    remote_net = Tables::Net.create!(
      server:, host: server.host, name: 'Remote Message Test Net', started_at: Time.now
    )
    remote_user = create_user(call_sign: 'K1REMOTE', first_name: 'Alex')
    remote_user.update!(monitoring_net: remote_net)
    REDIS.set("netlogger:cooldown:SendAIMMessage.php:#{remote_net.id}:#{remote_user.id}", '1', ex: 30)

    post "/api/message/#{remote_net.id}", { message: 'Hello again' }, auth_headers_for(remote_user)

    expect(last_response.status).to eq(429)
    expect(JSON.parse(last_response.body)).to eq('error' => 'Slow down.')
    expect(remote_net.messages.count).to eq(0)
  end
end
