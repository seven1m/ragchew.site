module Tables
  class SuggestedCanonicalNetMerge < ActiveRecord::Base
    validates :signature, presence: true, uniqueness: true

    def canonical_net_ids
      JSON.parse(self[:canonical_net_ids] || '[]')
    rescue JSON::ParserError
      []
    end

    def raw_names
      JSON.parse(self[:raw_names] || '[]')
    rescue JSON::ParserError
      []
    end

    def canonical_nets
      ids = canonical_net_ids
      return [] if ids.empty?

      nets = Tables::CanonicalNet.where(id: ids).index_by(&:id)
      ids.filter_map { |id| nets[id] }
    end
  end
end
