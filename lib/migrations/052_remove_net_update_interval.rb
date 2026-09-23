class RemoveNetUpdateInterval < ActiveRecord::Migration[7.0]
  def change
    remove_column :nets, :update_interval, :integer
  end
end
