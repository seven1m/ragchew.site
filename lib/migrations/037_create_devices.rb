class CreateDevices < ActiveRecord::Migration[7.0]
  def change
    create_table :devices do |t|
      t.references :user, null: false, foreign_key: true
      t.string :token, limit: 255, null: false
      t.string :platform, limit: 255, null: false
      t.datetime :last_used_at
      t.datetime :created_at, null: false
      t.datetime :updated_at, null: false

      t.index :token, unique: true
    end
  end
end
