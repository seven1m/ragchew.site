module Tables
  class CanonicalNet < ActiveRecord::Base
    belongs_to :club, optional: true
    has_many :nets, dependent: :nullify
    has_many :closed_nets, dependent: :nullify
    has_many :favorite_nets, dependent: :delete_all

    validates :canonical_name, presence: true

    before_validation :normalize_fields

    def self.find_or_create_for_name!(name, club_id: nil)
      cleaned_name = name.to_s.strip
      raise ActiveRecord::RecordInvalid, new if cleaned_name.empty?

      find_by(canonical_name: cleaned_name) || create!(canonical_name: cleaned_name, club_id:)
    end

    def all_names
      ([canonical_name] + nets.pluck(:name) + closed_nets.pluck(:name)).compact.map(&:strip).reject(&:empty?).uniq.sort
    end

    def representative_active_net
      nets.order(Arel.sql("case when name = #{ActiveRecord::Base.connection.quote(canonical_name)} then 0 else 1 end"), started_at: :desc, id: :desc).first
    end

    def representative_closed_net
      closed_nets.order(started_at: :desc, id: :desc).first
    end

    def favorite_count
      favorite_nets.count
    end

    def alias_details
      active_counts = nets.group(:name).count
      closed_counts = closed_nets.group(:name).count

      (active_counts.keys + closed_counts.keys + [canonical_name]).compact.map(&:strip).reject(&:empty?).uniq.sort.map do |name|
        {
          name:,
          active_count: active_counts[name].to_i,
          closed_count: closed_counts[name].to_i,
          canonical_name: name == self.canonical_name,
        }
      end
    end

    def merge!(other_groups:, canonical_name:)
      other_groups = Array(other_groups).compact.reject { |group| group.id == id }
      new_name = canonical_name.to_s.strip.presence || self.canonical_name
      merged_club_id = club_id || other_groups.map(&:club_id).compact.first

      transaction do
        self.club_id = merged_club_id if merged_club_id
        update!(canonical_name: new_name)

        unless other_groups.empty?
          other_ids = other_groups.map(&:id)
          Tables::Net.where(canonical_net_id: other_ids).update_all(canonical_net_id: id)
          Tables::ClosedNet.where(canonical_net_id: other_ids).update_all(canonical_net_id: id)

          Tables::FavoriteNet.where(canonical_net_id: other_ids).find_each do |favorite|
            existing = Tables::FavoriteNet.find_by(user_id: favorite.user_id, canonical_net_id: id)
            if existing
              favorite.destroy!
            else
              favorite.update!(canonical_net_id: id, net_name: self.canonical_name)
            end
          end

          other_groups.each(&:destroy!)
        end

        favorite_nets.update_all(net_name: self.canonical_name)
      end
    end

    def split_out_alias!(alias_name:)
      alias_name = alias_name.to_s.strip
      raise ArgumentError, 'alias name required' if alias_name.empty?
      raise ArgumentError, 'cannot split the canonical name directly' if alias_name == canonical_name

      transaction do
        new_canonical = self.class.find_or_create_for_name!(alias_name, club_id:)
        Tables::Net.where(canonical_net_id: id, name: alias_name).update_all(canonical_net_id: new_canonical.id)
        Tables::ClosedNet.where(canonical_net_id: id, name: alias_name).update_all(canonical_net_id: new_canonical.id)
        new_canonical
      end
    end

    def destroy_with_splits!
      raise ArgumentError, 'cannot delete a canonical net that still has favorites' if favorite_nets.exists?

      source_id = id
      raw_names = (nets.distinct.pluck(:name) + closed_nets.distinct.pluck(:name)).compact.map(&:strip).reject(&:empty?).uniq

      transaction do
        if raw_names.include?(canonical_name)
          update!(canonical_name: "__deleted_canonical_net_#{id}_#{Time.now.to_i}")
        end

        raw_names.each do |name|
          new_canonical = self.class.find_or_create_for_name!(name, club_id:)
          Tables::Net.where(canonical_net_id: source_id, name: name).update_all(canonical_net_id: new_canonical.id)
          Tables::ClosedNet.where(canonical_net_id: source_id, name: name).update_all(canonical_net_id: new_canonical.id)
        end

        destroy!
      end
    end

    private

    def normalize_fields
      self.canonical_name = canonical_name.to_s.strip
      self.normalized_name = CanonicalNetResolver.normalize_name(canonical_name)
      self.compressed_name = CanonicalNetResolver.compressed_name(canonical_name)
    end
  end
end
