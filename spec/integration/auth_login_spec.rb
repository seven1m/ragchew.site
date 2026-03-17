# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'auth login' do
  def json_response
    JSON.parse(last_response.body)
  end

  def login_with(call_sign:, password:)
    post '/api/auth/login',
      JSON.generate(call_sign:, password:),
      {
        'CONTENT_TYPE' => 'application/json',
        'HTTP_ACCEPT' => 'application/json',
        'REMOTE_ADDR' => '127.0.0.1'
      }
  end

  def web_login_with(call_sign:, password:, net: nil)
    params = { call_sign:, password: }
    params[:net] = net if net

    post '/login', params
  end

  it 'logs in the apple review demo user' do
    stub_const('APPLE_REVIEW_DEMO_ENABLED', true)
    user = create_user(call_sign: APPLE_REVIEW_DEMO_CALL_SIGN, first_name: 'Review', last_name: 'Demo')
    user.test_user = true
    user.save!

    login_with(call_sign: APPLE_REVIEW_DEMO_CALL_SIGN, password: APPLE_REVIEW_DEMO_PASSWORD)

    expect(last_response.status).to eq(200)
    expect(json_response['token']).not_to be_nil
    expect(json_response.dig('user', 'call_sign')).to eq(APPLE_REVIEW_DEMO_CALL_SIGN)
    expect(user.reload.last_signed_in_at).not_to be_nil
  end

  it 'logs into the website with the apple review demo user' do
    stub_const('APPLE_REVIEW_DEMO_ENABLED', true)
    user = create_user(call_sign: APPLE_REVIEW_DEMO_CALL_SIGN, first_name: 'Review', last_name: 'Demo')
    user.test_user = true
    user.save!

    web_login_with(call_sign: APPLE_REVIEW_DEMO_CALL_SIGN, password: APPLE_REVIEW_DEMO_PASSWORD)

    expect(last_response.status).to eq(302)
    expect(last_response.headers['Location']).to eq('http://example.org/')
    expect(rack_mock_session.cookie_jar['rack.session']).not_to be_nil
    expect(user.reload.last_signed_in_at).not_to be_nil
  end
end
