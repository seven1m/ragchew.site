module Tables
  class FavoriteNet < ActiveRecord::Base
    validates :net_name, presence: true
    belongs_to :user, class_name: 'Tables::User'
    belongs_to :canonical_net, class_name: 'Tables::CanonicalNet', optional: true

    before_validation :sync_canonical_name

    private

    def sync_canonical_name
      if canonical_net
        self.net_name = canonical_net.canonical_name
      elsif net_name.present?
        self.canonical_net ||= CanonicalNetResolver.resolve(net_name) || CanonicalNetResolver.ensure_for_name!(net_name)
        self.net_name = canonical_net.canonical_name if canonical_net
      end
    end
  end
end
