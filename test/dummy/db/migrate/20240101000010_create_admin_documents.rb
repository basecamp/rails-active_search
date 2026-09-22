class CreateAdminDocuments < ActiveRecord::Migration[7.0]
  def change
    create_table :admin_documents do |t|
      t.string :title
      t.text :body
      t.bigint :account_id
      t.timestamps
    end
  end
end
