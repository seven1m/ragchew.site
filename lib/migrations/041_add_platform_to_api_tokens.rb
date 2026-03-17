class AddPlatformToApiTokens < ActiveRecord::Migration[7.2]
  def up
    add_column :api_tokens, :platform, :string, limit: 255
    execute <<~SQL
      UPDATE api_tokens
      SET platform = 'unknown'
      WHERE platform IS NULL
    SQL
    change_column_null :api_tokens, :platform, false
  end

  def down
    remove_column :api_tokens, :platform
  end
end
