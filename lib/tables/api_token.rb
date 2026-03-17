require 'digest'

module Tables
  class ApiToken < ActiveRecord::Base
    belongs_to :user

    MAX_TOKENS_PER_USER = 5

    validates :token, presence: true, uniqueness: true
    validates :platform, presence: true

    def self.generate_for(user, platform:)
      raw_token = SecureRandom.hex(32)
      api_token = create!(
        user: user,
        platform: platform,
        token: Digest::SHA256.hexdigest(raw_token),
        expires_at: 365.days.from_now,
      )

      # Clean up old tokens beyond the limit
      old_tokens = user.api_tokens.order(created_at: :desc).offset(MAX_TOKENS_PER_USER)
      old_tokens.delete_all if old_tokens.any?

      api_token.define_singleton_method(:raw_token) { raw_token }
      api_token
    end

    def self.find_by_raw_token(raw_token)
      return nil if raw_token.blank?

      find_by(token: Digest::SHA256.hexdigest(raw_token))
    end

    def expired?
      expires_at && expires_at < Time.now
    end

    def touch_last_used!
      return if last_used_at && Time.now - last_used_at < 20 * 60

      update!(last_used_at: Time.now)
    end
  end
end
