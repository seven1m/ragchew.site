class CreateIgnoredCanonicalNetSuggestions < ActiveRecord::Migration[7.0]
  def change
    create_table :ignored_canonical_net_suggestions do |t|
      t.string :signature, null: false
      t.text :summary
      t.timestamps
    end

    add_index :ignored_canonical_net_suggestions, :signature, unique: true
  end
end
