module Tables
  class Club < ActiveRecord::Base
    has_many :canonical_nets, dependent: :nullify
    has_many :nets, dependent: :nullify
    has_many :closed_nets, dependent: :nullify
    has_many :club_stations, dependent: :delete_all
    has_many :club_members, dependent: :delete_all
    has_many :users, through: :club_members

    serialize :net_patterns, coder: JSON
    serialize :additional_net_patterns, coder: JSON
    serialize :net_list, coder: JSON

    scope :order_by_name, -> { order(Arel.sql('coalesce(full_name, name)')) }

    validates :name, presence: true

    def best_name
      full_name.presence || name
    end

    def as_json
      super.merge(best_name:)
    end

    # returns an array of hashes, like this:
    #
    #     [
    #       { name: 'YL*' },
    #       { name: 'YL System 15m Session', frequency: '21.373' },
    #       ...
    #     ]
    #
    def all_net_conditions
      net_pattern_conditions +
        additional_net_pattern_conditions +
        net_list_conditions
    end

    def matches_net?(net)
      all_net_conditions.any? do |condition|
        name_matches = name_to_regexp(condition[:name]).match?(net.name)
        if (frequency = condition[:frequency])
          name_matches && frequency.downcase == net.frequency.to_s.downcase
        else
          name_matches
        end
      end
    end

    private

    def net_pattern_conditions
      strings_to_conditions(net_patterns)
    end

    def additional_net_pattern_conditions
      strings_to_conditions(additional_net_patterns)
    end

    def strings_to_conditions(strings)
      if strings.is_a?(Array)
        strings.map do |name|
          if name.is_a?(String)
            { name: }
          end
        end.compact
      else
        []
      end
    end

    def name_to_regexp(name)
      Regexp.new(Regexp.escape(name).gsub(/\\\*/, '.*'), 'i')
    end

    def net_list_conditions
      if net_list.is_a?(Array)
        net_list.map do |net|
          if net.is_a?(Hash)
            if net['name'].is_a?(String)
              {
                name: net['name'],
                frequency: net['frequency'],
              }
            end
          end
        end.compact
      else
        []
      end
    end
  end
end
