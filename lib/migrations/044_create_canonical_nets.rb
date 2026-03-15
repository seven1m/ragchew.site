class CreateCanonicalNets < ActiveRecord::Migration[7.0]
  def change
    create_table :canonical_nets do |t|
      t.string :canonical_name, null: false
      t.string :normalized_name, null: false
      t.string :compressed_name, null: false
      t.timestamps
    end

    add_column :nets, :canonical_net_id, :integer
    add_column :closed_nets, :canonical_net_id, :integer
    add_column :favorite_nets, :canonical_net_id, :integer

    add_index :canonical_nets, :canonical_name, unique: true
    add_index :canonical_nets, :normalized_name
    add_index :canonical_nets, :compressed_name
    add_index :nets, :canonical_net_id
    add_index :closed_nets, :canonical_net_id
    add_index :favorite_nets, :canonical_net_id
    add_index :favorite_nets, [:user_id, :canonical_net_id], unique: true
  end
end
