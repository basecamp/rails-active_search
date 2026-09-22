class CreateCommentDocuments < ActiveRecord::Migration[7.0]
  def change
    adapter = connection.adapter_name.downcase

    create_table :comment_documents do |t|
      t.string :comment_id, null: false
      t.text :body
      t.bigint :account_id
      t.bigint :article_id
      t.boolean :approved
      t.datetime :published_at
    end

    add_index :comment_documents, :comment_id, unique: true

    case adapter
    when "mysql2"
      add_index :comment_documents, :body, type: :fulltext
    when "postgresql"
      add_column :comment_documents, :body_vector, :tsvector
      add_index :comment_documents, :body_vector, using: :gin
    when "sqlite"
      create_virtual_table :comment_documents_fts, :fts5, [ "body" ]
    end
  end
end
