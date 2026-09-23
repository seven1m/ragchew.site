class RemoveCreatedByRagchew < ActiveRecord::Migration[7.0]
  def change
    remove_column :nets, :created_by_ragchew, :boolean, default: false
    remove_column :closed_nets, :created_by_ragchew, :boolean, default: false
  end
end
