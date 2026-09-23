class AddNetloggerXmlCacheState < ActiveRecord::Migration[7.0]
  def change
    add_column :nets, :checkins_fetched_at, :datetime
    add_column :nets, :aim_fetched_at, :datetime
    add_column :nets, :monitors_fetched_at, :datetime
    add_column :nets, :aim_next_request_id, :integer
  end
end
