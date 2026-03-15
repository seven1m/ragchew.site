namespace :canonical_nets do
  desc 'Backfill canonical net ids for existing nets, closed nets, and favorite nets'
  task :backfill do
    net_scope = Tables::Net.where(canonical_net_id: nil)
    closed_net_scope = Tables::ClosedNet.where(canonical_net_id: nil)
    favorite_net_scope = Tables::FavoriteNet.where(canonical_net_id: nil)

    puts "Starting canonical net backfill"
    puts "  nets missing: #{net_scope.count}"
    puts "  closed nets missing: #{closed_net_scope.count}"
    puts "  favorite nets missing: #{favorite_net_scope.count}"

    names = (
      net_scope.pluck(:name) +
      closed_net_scope.pluck(:name) +
      favorite_net_scope.pluck(:net_name)
    ).compact.map(&:strip).reject(&:empty?).uniq

    puts "Ensuring canonical names for #{names.size} unique raw names"

    names.each do |name|
      CanonicalNetResolver.ensure_for_name!(name)
    end

    backfill_scope('nets', net_scope) do |net|
      canonical_net = CanonicalNetResolver.resolve(net.name) || CanonicalNetResolver.ensure_for_name!(net.name)
      net.update_columns(canonical_net_id: canonical_net.id)
    end

    backfill_scope('closed nets', closed_net_scope) do |closed_net|
      canonical_net = CanonicalNetResolver.resolve(closed_net.name) || CanonicalNetResolver.ensure_for_name!(closed_net.name)
      closed_net.update_columns(canonical_net_id: canonical_net.id)
    end

    backfill_scope('favorite nets', favorite_net_scope) do |favorite_net|
      canonical_net = CanonicalNetResolver.resolve(favorite_net.net_name) || CanonicalNetResolver.ensure_for_name!(favorite_net.net_name)
      existing = Tables::FavoriteNet.find_by(user_id: favorite_net.user_id, canonical_net_id: canonical_net.id)
      if existing && existing.id != favorite_net.id
        favorite_net.destroy!
      else
        favorite_net.update_columns(canonical_net_id: canonical_net.id, net_name: canonical_net.canonical_name)
      end
    end

    puts "Backfill complete"
    puts "  nets missing: #{Tables::Net.where(canonical_net_id: nil).count}"
    puts "  closed nets missing: #{Tables::ClosedNet.where(canonical_net_id: nil).count}"
    puts "  favorite nets missing: #{Tables::FavoriteNet.where(canonical_net_id: nil).count}"
  end

  desc 'Rebuild cached canonical net merge suggestions'
  task :build_suggestions do
    CanonicalNetResolver.rebuild_cached_suggestions!(progress: ->(message) { puts message })
  end
end

def backfill_scope(label, scope, batch_size: 1000)
  total = scope.count
  processed = 0
  puts "Processing #{label}: #{total} rows"

  scope.find_each(batch_size:) do |record|
    yield record
    processed += 1
    if (processed % batch_size).zero? || processed == total
      puts "  #{label}: #{processed}/#{total}"
    end
  end
end
