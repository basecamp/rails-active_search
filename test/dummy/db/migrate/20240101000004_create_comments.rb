class CreateComments < ActiveRecord::Migration[7.0]
  def change
    create_table :comments do |t|
      t.text :body
      t.bigint :account_id
      t.bigint :article_id
      t.boolean :approved, default: false
      t.datetime :published_at
      t.timestamps
    end
  end
end
