class AddEcholinkToNetsAndClosedNets < ActiveRecord::Migration[7.2]
  def change
    add_column :nets, :echolink, :json
    add_column :closed_nets, :echolink, :json
  end
end
