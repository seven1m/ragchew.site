require_relative '../net_like'

module Tables
  class Net < ActiveRecord::Base
    include NetLike

    belongs_to :server
    belongs_to :club, optional: true
    has_many :logging_users, class_name: 'User', foreign_key: 'logging_net_id'
    has_many :checkins, dependent: :delete_all
    has_many :monitors, dependent: :delete_all
    has_many :messages, dependent: :delete_all
    has_many :message_reactions, dependent: :delete_all
    has_many :blocked_stations, as: :blocker, dependent: :delete_all

    after_create :send_notifications

    def self.all_by_name
      all.each_with_object({}) do |net, hash|
        hash[net.name] = net
      end
    end

    def update_interval_in_seconds
      if update_interval
        update_interval / 1000
      else
        20
      end
    end

    private

    def send_notifications
      Tables::FavoriteNet.where(net_name: name).includes(user: :devices).find_each do |fave|
        fave.user.devices.each do |device|
          suffix = name.match?(/\bnet\z/i) ? " is starting!" : " net is starting!"
          device.send_push_notification(body: "#{name}#{suffix}", data: { netName: name })
        end
      end
    end
  end
end
