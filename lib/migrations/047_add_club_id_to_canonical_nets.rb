class AddClubIdToCanonicalNets < ActiveRecord::Migration[7.0]
  def change
    add_column :canonical_nets, :club_id, :integer
    add_index :canonical_nets, :club_id
  end
end
