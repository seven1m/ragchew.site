# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'user page' do
  def session_env_for(user)
    { 'rack.session' => { user_id: user.id } }
  end

  it 'shows logged in devices with platform and last used time' do
    user = create_user(call_sign: 'K1ABC', first_name: 'Test', last_name: 'User')
    ios_token = Tables::ApiToken.generate_for(user, platform: 'ios')
    ios_token.update!(last_used_at: Time.utc(2026, 3, 16, 12, 30, 0))
    Tables::ApiToken.generate_for(user, platform: 'android')

    get '/user', {}, session_env_for(user)

    expect(last_response.status).to eq(200)
    expect(last_response.body).to include('Logged In Devices')
    expect(last_response.body).to include('ios')
    expect(last_response.body).to include('android')
    expect(last_response.body).to include('2026-03-16 12:30:00 UTC')
    expect(last_response.body).to include('last used never')
  end

  it 'allows a user to log out one device without affecting others' do
    user = create_user(call_sign: 'K1ABC', first_name: 'Test', last_name: 'User')
    keep_token = Tables::ApiToken.generate_for(user, platform: 'ios')
    revoke_token = Tables::ApiToken.generate_for(user, platform: 'android')

    delete "/user/api_tokens/#{revoke_token.id}", {}, session_env_for(user)

    expect(last_response.status).to eq(302)
    expect(last_response.headers['Location']).to eq('http://example.org/user')
    expect(Tables::ApiToken.exists?(revoke_token.id)).to eq(false)
    expect(Tables::ApiToken.exists?(keep_token.id)).to eq(true)
  end

  it 'does not allow revoking another users device token' do
    user = create_user(call_sign: 'K1ABC', first_name: 'Test', last_name: 'User')
    other_user = create_user(call_sign: 'K1XYZ', first_name: 'Other', last_name: 'User')
    other_token = Tables::ApiToken.generate_for(other_user, platform: 'ios')

    delete "/user/api_tokens/#{other_token.id}", {}, session_env_for(user)

    expect(last_response.status).to eq(404)
    expect(Tables::ApiToken.exists?(other_token.id)).to eq(true)
  end
end
