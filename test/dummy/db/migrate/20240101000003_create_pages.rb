class CreatePages < ActiveRecord::Migration[7.0]
  def change
    create_table :pages do |t|
      t.string :title
      t.text :content
      t.bigint :account_id
      t.string :status, default: "published"
      t.timestamps
    end
  end
end
