class AddPriorityToArticles < ActiveRecord::Migration[7.0]
  def change
    add_column :articles, :priority, :integer
  end
end
