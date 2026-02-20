require_relative '../bit_flags'
require 'net/http'
require 'json'

module Tables
  class Device < ActiveRecord::Base
    belongs_to :user

    EXPO_PUSH_URL = URI('https://exp.host/--/api/v2/push/send')

    def send_push_notification(body:, title: nil, data: {})
      payload = { to: token, body:, title:, data: }.compact

      http = ::Net::HTTP.new(EXPO_PUSH_URL.host, EXPO_PUSH_URL.port)
      http.use_ssl = true

      request = ::Net::HTTP::Post.new(EXPO_PUSH_URL.path)
      request['Content-Type'] = 'application/json'
      request['Accept'] = 'application/json'
      request.body = payload.to_json

      response = http.request(request)

      unless response.is_a?(::Net::HTTPSuccess)
        raise "Expo push notification failed (#{response.code}): #{response.body}"
      end

      response
    end
  end
end
