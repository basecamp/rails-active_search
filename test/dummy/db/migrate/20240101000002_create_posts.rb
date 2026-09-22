class CreatePosts < ActiveRecord::Migration[7.0]
  def change
    create_table :posts do |t|
      t.string :headline
      t.text :body
      t.bigint :account_id
      t.string :status, default: "published"
      t.timestamps
    end
  end
end
