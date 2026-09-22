class CreateArticleDocuments < ActiveRecord::Migration[7.0]
  def change
    adapter = connection.adapter_name.downcase

    create_table :article_documents do |t|
      t.string :article_id, null: false
      t.text :title
      t.text :content
      t.bigint :account_id
      t.string :status
      t.datetime :published_at
      t.boolean :featured
    end

    add_index :article_documents, :article_id, unique: true

    case adapter
    when "mysql2"
      add_index :article_documents, [ :title, :content ], type: :fulltext
      add_index :article_documents, :title, type: :fulltext
      add_index :article_documents, :content, type: :fulltext
    when "postgresql"
      add_column :article_documents, :title_vector, :tsvector
      add_column :article_documents, :content_vector, :tsvector
      add_index :article_documents, :title_vector, using: :gin
      add_index :article_documents, :content_vector, using: :gin
    when "sqlite"
      create_virtual_table :article_documents_fts, :fts5, [ "title", "content" ]
    end
  end
end
