require_relative '../net_like'

module Tables
  class Net < ActiveRecord::Base
    include NetLike

    belongs_to :server
    belongs_to :club, optional: true
    belongs_to :canonical_net, optional: true
    has_many :logging_users, class_name: 'User', foreign_key: 'logging_net_id'
    has_many :checkins, dependent: :delete_all
    has_many :monitors, dependent: :delete_all
    has_many :messages, dependent: :delete_all
    has_many :message_reactions, dependent: :delete_all
    has_many :blocked_stations, as: :blocker, dependent: :delete_all

    after_create :send_notifications
    before_validation :assign_canonical_net

    def update_interval_in_seconds
      if update_interval
        update_interval / 1000
      else
        20
      end
    end

    private

    def assign_canonical_net
      return unless name.present?

      self.canonical_net ||= CanonicalNetResolver.ensure_for_name!(name)
    end

    def send_notifications
      return unless canonical_net

      Tables::FavoriteNet.where(canonical_net_id: canonical_net_id).includes(user: :devices).find_each do |fave|
        fave.user.devices.each do |device|
          next unless device.should_send_notification?(:favorite_net)

          suffix = canonical_net.canonical_name.match?(/\bnet\z/i) ? " is starting!" : " net is starting!"
          device.send_push_notification(
            body: "#{canonical_net.canonical_name}#{suffix}",
            data: { netName: canonical_net.canonical_name }
          )
        end
      end
    end
  end
end
