require_relative '../bit_flags'

module Tables
  class User < ActiveRecord::Base
    include BitFlags

    bit_flag :admin, 0
    bit_flag :net_logger, 1
    bit_flag :net_creation_blocked, 2

    def net_logger?
      true
    end
    validates :call_sign, presence: true

    belongs_to :monitoring_net, class_name: 'Net'
    has_many :favorites, dependent: :delete_all
    has_many :favorite_nets, dependent: :delete_all
    belongs_to :logging_net, class_name: 'Net', optional: true
    has_many :club_members, dependent: :delete_all
    has_many :clubs, through: :club_members
    has_many :blocked_stations, as: :blocker, dependent: :delete_all
    has_many :api_tokens, dependent: :delete_all
    has_many :devices, dependent: :delete_all

    scope :is_monitoring, -> { where.not(monitoring_net_id: nil) }

    enum :time_format, {
      local_24: 0,
      local_12: 1,
      utc_24: 2,
    }

    validates :theme, inclusion: { in: %w[system light dark] }

    def name
      [first_name, last_name].compact.join(' ')
    end

    def can_log_for_club?(club)
      return false unless club
      return false unless net_logger?

      club_members.where(club_id: club.id).exists?
    end

    def one_time_user?
      last_signed_in_at && created_at && (last_signed_in_at - created_at) < (12 * 60 * 60)
    end
  end
end
