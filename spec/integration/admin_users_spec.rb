# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'admin users' do
  def session_env_for(user)
    { 'rack.session' => { user_id: user.id } }
  end

  it 'shows web and mobile activity stats on the users page' do
    admin = create_user(call_sign: 'K1ADMIN', first_name: 'Admin', last_name: 'User')
    admin.update!(admin: true, last_web_active_at: 2.hours.ago)

    web_user = create_user(call_sign: 'K1WEB', first_name: 'Web', last_name: 'User')
    web_user.update!(last_web_active_at: 3.days.ago, last_signed_in_at: 10.days.ago)

    mobile_user = create_user(call_sign: 'K1APP', first_name: 'App', last_name: 'User')
    mobile_user.update!(last_mobile_active_at: 12.hours.ago, last_signed_in_at: 5.days.ago)

    get '/admin/users', {}, session_env_for(admin)

    expect(last_response.status).to eq(200)
    expect(last_response.body).to include('Total user count:')
    expect(last_response.body).to include('Period')
    expect(last_response.body).to include('Web')
    expect(last_response.body).to include('Mobile')
    expect(last_response.body).to include('30 days')
    expect(last_response.body).to include('7 days')
    expect(last_response.body).to include('24 hours')
    expect(last_response.body).to include('1 hour')
    expect(last_response.body).to include('Last Web Active')
    expect(last_response.body).to include('Last Mobile Active')
    expect(last_response.body).to include('K1WEB')
    expect(last_response.body).to include('K1APP')
  end

  it 'renders weekly web and mobile activity bars on the admin dashboard' do
    admin = create_user(call_sign: 'K1ADMIN', first_name: 'Admin', last_name: 'User')
    admin.update!(admin: true, last_web_active_at: 2.hours.ago)

    week = Time.current.beginning_of_week
    Tables::Stat.create!(name: 'new_users_per_week', period: week, value: 2)
    Tables::Stat.create!(name: 'active_web_users_per_week', period: week, value: 5)
    Tables::Stat.create!(name: 'active_mobile_users_per_week', period: week, value: 3)

    get '/admin', {}, session_env_for(admin)

    expect(last_response.status).to eq(200)
    expect(last_response.body).to include('Last Web Active')
    expect(last_response.body).to include('Last Mobile Active')
    expect(last_response.body).not_to include('Last Signed In')
    expect(last_response.body).to include('web active')
    expect(last_response.body).to include('mobile active')
    expect(last_response.body).to include('unique web users over the last 30 days')
  end
end
