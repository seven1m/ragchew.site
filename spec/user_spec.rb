# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Tables::User do
  it 'treats users with activity well after signup as returning users' do
    created_at = 3.days.ago
    user = create_user(call_sign: 'K1RETURN', first_name: 'Return', last_name: 'User')
    user.update!(
      created_at: created_at,
      last_signed_in_at: created_at + 1.hour,
      last_web_active_at: created_at + 2.days
    )

    expect(user.one_time_user?).to be(false)
  end

  it 'falls back to last signed in when activity timestamps are missing' do
    created_at = 2.days.ago
    user = create_user(call_sign: 'K1LEGACY', first_name: 'Legacy', last_name: 'User')
    user.update!(
      created_at: created_at,
      last_signed_in_at: created_at + 1.hour,
      last_web_active_at: nil,
      last_mobile_active_at: nil
    )

    expect(user.one_time_user?).to be(true)
  end
end
