class CreateArticles < ActiveRecord::Migration[7.0]
  def change
    create_table :articles do |t|
      t.string :title
      t.text :content
      t.bigint :account_id
      t.string :status, default: "published"
      t.datetime :published_at
      t.boolean :featured, default: false
      t.timestamps
    end
  end
end
