# frozen_string_literal: true

ENV['RACK_ENV'] = 'test'
ENV['REDIS_URL'] ||= 'redis://127.0.0.1:6379'
ENV['REDIS_DB'] ||= '15'
ENV['PUSHER_URL'] ||= 'http://test:test@127.0.0.1/apps/1'
ENV['SESSION_SECRET'] ||= 'test-session-secret-test-session-secret-test-session-secret-test-session-secret'
ENV['APPLE_REVIEW_DEMO_PASSWORD'] = 'test'

require 'rack/test'
require 'webmock/rspec'
require_relative '../app'

Dir[File.expand_path('support/**/*.rb', __dir__)].sort.each { |file| require file }

module SpecHelpers
  def app
    Sinatra::Application
  end

  def create_user(call_sign:, first_name: nil, last_name: nil)
    Tables::User.create!(
      call_sign: call_sign,
      first_name: first_name,
      last_name: last_name,
      theme: 'system'
    )
  end

  def bearer_token_for(user)
    Tables::ApiToken.generate_for(user, platform: 'test').raw_token
  end

  def auth_headers_for(user)
    {
      'HTTP_AUTHORIZATION' => "Bearer #{bearer_token_for(user)}",
      'HTTP_ACCEPT' => 'application/json',
      'REMOTE_ADDR' => '127.0.0.1'
    }
  end

  def netlogger_html(inner)
    <<~HTML
      <!DOCTYPE html PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN"
       "https://www.w3.org/TR/html4/loose.dtd">
      <html>
      <head>
      <title>
      </title>
      </head>
      <body>
      *success* #{inner}
      </body>
      </html>
    HTML
  end

  def stub_netlogger_xml_updates(checkins: '', pointer: 0)
    base = 'https://www.netlogger.org/api'
    header = '<Header><CreationDateUTC>Thu 03/05/2026 03:00:00</CreationDateUTC><TimeZone>UTC</TimeZone></Header>'
    stub_request(:get, %r{#{Regexp.escape(base)}/GetCheckins\.php})
      .to_return(status: 200, body: "<NetLoggerXML>#{header}<CheckinList><ResponseCode>200 OK</ResponseCode><Pointer>#{pointer}</Pointer>#{checkins}</CheckinList></NetLoggerXML>")
    stub_request(:get, %r{#{Regexp.escape(base)}/GetAIM\.php})
      .to_return(status: 200, body: "<NetLoggerXML>#{header}<AIMTranscript><ResponseCode>404 Not Found</ResponseCode><AIMNextRequestID>0</AIMNextRequestID></AIMTranscript></NetLoggerXML>")
    stub_request(:get, %r{#{Regexp.escape(base)}/GetMonitors\.php})
      .to_return(status: 200, body: "<NetLoggerXML>#{header}<MonitorList><ResponseCode>404 Not Found</ResponseCode></MonitorList></NetLoggerXML>")
  end
end

RSpec.configure do |config|
  config.include Rack::Test::Methods
  config.include SpecHelpers
  config.order = :defined

  config.before(:suite) do
    WebMock.disable_net_connect!(allow_localhost: true)
  end

  config.before do
    REDIS.flushdb
    allow(Honeybadger).to receive(:notify)
    fake_pusher = instance_double(Pusher::Client, trigger: true, authenticate: { auth: 'ok' })
    allow(Pusher::Client).to receive(:from_env).and_return(fake_pusher)
  end

  config.around do |example|
    connection = ActiveRecord::Base.connection
    connection.begin_transaction(joinable: false)
    example.run
  ensure
    connection.rollback_transaction if connection.transaction_open?
  end
end
