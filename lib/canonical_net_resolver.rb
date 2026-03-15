require 'set'

class CanonicalNetResolver
  Suggestion = Struct.new(
    :band,
    :frequency,
    :canonical_nets,
    :raw_names,
    :normalized_name,
    :signature,
    keyword_init: true
  )

  class << self
    def normalize_name(name)
      name
        .to_s
        .downcase
        .gsub(/[^a-z0-9]+/, ' ')
        .split
        .map { |token| normalize_token(token) }
        .join(' ')
    end

    def compressed_name(name)
      normalize_name(name).gsub(/[^a-z0-9]+/, '')
    end

    def ensure_for_name!(name)
      Tables::CanonicalNet.find_or_create_for_name!(name)
    end

    def resolve(name)
      cleaned_name = name.to_s.strip
      return if cleaned_name.empty?

      Tables::CanonicalNet.find_by(canonical_name: cleaned_name) ||
        Tables::Net.find_by(name: cleaned_name)&.canonical_net ||
        Tables::ClosedNet.where(name: cleaned_name).order(started_at: :desc).first&.canonical_net
    end

    def representative_for(canonical_net)
      active = canonical_net.representative_active_net
      return { type: :active, record: active } if active

      closed = canonical_net.representative_closed_net
      return { type: :closed, record: closed } if closed

      nil
    end

    def computed_suggestions(limit: 20)
      ignored_signatures = Tables::IgnoredCanonicalNetSuggestion.pluck(:signature).to_set
      groups = Hash.new { |hash, key| hash[key] = [] }
      rows_for_suggestions.each do |row|
        next if row[:canonical_net_id].nil?

        signature = [
          row[:band].to_s.downcase,
          row[:frequency].to_s.downcase,
        ]
        groups[signature] << row
      end

      groups.values.filter_map do |rows|
        canonical_ids = rows.map { |row| row[:canonical_net_id] }.uniq
        next if canonical_ids.size < 2

        clusters = build_name_clusters(rows)
        next if clusters.empty?

        clusters.map do |cluster|
          ids = cluster.map { |row| row[:canonical_net_id] }.uniq
          next if ids.size < 2

          canonical_nets = Tables::CanonicalNet.where(id: ids).order(:canonical_name).to_a
          next if canonical_nets.size < 2

          Suggestion.new(
            band: rows.first[:band],
            frequency: rows.first[:frequency],
            normalized_name: normalize_name(cluster.first[:name]),
            signature: suggestion_signature(
              rows.first[:frequency],
              rows.first[:band],
              canonical_nets.map(&:canonical_name)
            ),
            canonical_nets: canonical_nets,
            raw_names: cluster.map { |row| row[:name] }.uniq.sort,
          )
        end.compact
      end.flatten.reject { |suggestion| ignored_signatures.include?(suggestion.signature) }
        .sort_by { |suggestion| [-suggestion.canonical_nets.size, suggestion.raw_names.first.to_s] }
        .first(limit)
    end

    def suggestions(limit: 20)
      rows = Tables::SuggestedCanonicalNetMerge.order(:band, :frequency, :normalized_name, :id).to_a
      rows.filter_map do |row|
        canonical_nets = row.canonical_nets
        next if canonical_nets.size < 2

        Suggestion.new(
          band: row.band,
          frequency: row.frequency,
          normalized_name: row.normalized_name,
          signature: row.signature,
          canonical_nets: canonical_nets,
          raw_names: row.raw_names,
        )
      end.first(limit)
    end

    def rebuild_cached_suggestions!(limit: 10_000, progress: nil)
      suggestions = computed_suggestions(limit:)
      progress&.call("Rebuilding canonical net suggestions: #{suggestions.size} suggestion(s)")

      Tables::SuggestedCanonicalNetMerge.transaction do
        Tables::SuggestedCanonicalNetMerge.delete_all

        suggestions.each_with_index do |suggestion, index|
          Tables::SuggestedCanonicalNetMerge.create!(
            signature: suggestion.signature,
            frequency: suggestion.frequency,
            band: suggestion.band,
            normalized_name: suggestion.normalized_name,
            canonical_net_ids: suggestion.canonical_nets.map(&:id).to_json,
            raw_names: suggestion.raw_names.to_json,
          )
          if progress && (((index + 1) % 100).zero? || index + 1 == suggestions.size)
            progress.call("  saved #{index + 1}/#{suggestions.size}")
          end
        end
      end

      progress&.call('Suggestion rebuild complete')
      suggestions.size
    end

    def suggestion_signature(frequency, band, canonical_names)
      [
        frequency.to_s.strip.downcase,
        band.to_s.strip.downcase,
        canonical_names.map { |name| compressed_name(name) }.sort.join('|'),
      ].join('::')
    end

    private

    def rows_for_suggestions
      active_rows = Tables::Net.select(:canonical_net_id, :name, :band, :frequency).map do |net|
        { canonical_net_id: net.canonical_net_id, name: net.name, band: net.band, frequency: net.frequency }
      end
      closed_rows = Tables::ClosedNet.where('started_at > ?', 180.days.ago).select(:canonical_net_id, :name, :band, :frequency).map do |net|
        { canonical_net_id: net.canonical_net_id, name: net.name, band: net.band, frequency: net.frequency }
      end
      active_rows + closed_rows
    end

    def build_name_clusters(rows)
      clusters = []
      rows.each do |row|
        matching_cluster = clusters.find { |cluster| cluster.any? { |existing| similar_names?(existing[:name], row[:name]) } }
        if matching_cluster
          matching_cluster << row
        else
          clusters << [row]
        end
      end
      clusters
    end

    def similar_names?(left, right)
      left_normalized = normalize_name(left)
      right_normalized = normalize_name(right)
      left_compressed = compressed_name(left)
      right_compressed = compressed_name(right)

      return true if left_normalized == right_normalized
      return false if left_compressed.empty? || right_compressed.empty?

      shorter, longer = [left_compressed, right_compressed].sort_by(&:length)
      return false if shorter.length < 10
      return false unless longer.include?(shorter)

      shorter.length.to_f / longer.length >= 0.8
    end

    def normalize_token(token)
      case token
      when '1st', 'first'
        'first'
      when '2nd', 'second'
        'second'
      when '3rd', 'third'
        'third'
      when '4th', 'fourth'
        'fourth'
      when 'w'
        'with'
      else
        token
      end
    end
  end
end
