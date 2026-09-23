class RemoveRagchewOnlyTestingNet < ActiveRecord::Migration[7.0]
  def change
    remove_column :nets,
                  :ragchew_only_testing_net,
                  :boolean,
                  null: false,
                  default: false
    remove_column :closed_nets,
                  :ragchew_only_testing_net,
                  :boolean,
                  null: false,
                  default: false
  end
end
