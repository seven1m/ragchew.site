class CreateSuggestedCanonicalNetMerges < ActiveRecord::Migration[7.0]
  def change
    create_table :suggested_canonical_net_merges do |t|
      t.string :signature, null: false
      t.string :frequency
      t.string :band
      t.string :normalized_name
      t.text :canonical_net_ids, null: false
      t.text :raw_names, null: false
      t.timestamps
    end

    add_index :suggested_canonical_net_merges, :signature, unique: true
  end
end
