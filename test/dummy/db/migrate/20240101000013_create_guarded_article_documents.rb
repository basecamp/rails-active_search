class CreateGuardedArticleDocuments < ActiveRecord::Migration[7.0]
  def change
    adapter = connection.adapter_name.downcase

    create_table :guarded_article_documents do |t|
      t.string :guarded_article_id, null: false
      t.text :title
      t.text :content
    end
    add_index :guarded_article_documents, :guarded_article_id, unique: true

    create_table :unless_guarded_article_documents do |t|
      t.string :unless_guarded_article_id, null: false
      t.text :title
      t.text :content
    end
    add_index :unless_guarded_article_documents, :unless_guarded_article_id, unique: true, name: "idx_unless_guarded_article_docs_on_id"

    create_table :proc_guarded_article_documents do |t|
      t.string :proc_guarded_article_id, null: false
      t.text :title
      t.text :content
      t.string :status
    end
    add_index :proc_guarded_article_documents, :proc_guarded_article_id, unique: true, name: "idx_proc_guarded_article_docs_on_id"

    case adapter
    when "mysql2"
      add_index :guarded_article_documents, [ :title, :content ], type: :fulltext
      add_index :unless_guarded_article_documents, [ :title, :content ], type: :fulltext
      add_index :proc_guarded_article_documents, [ :title, :content ], type: :fulltext
    when "postgresql"
      add_column :guarded_article_documents, :title_vector, :tsvector
      add_column :guarded_article_documents, :content_vector, :tsvector
      add_index :guarded_article_documents, :title_vector, using: :gin
      add_index :guarded_article_documents, :content_vector, using: :gin

      add_column :unless_guarded_article_documents, :title_vector, :tsvector
      add_column :unless_guarded_article_documents, :content_vector, :tsvector
      add_index :unless_guarded_article_documents, :title_vector, using: :gin
      add_index :unless_guarded_article_documents, :content_vector, using: :gin

      add_column :proc_guarded_article_documents, :title_vector, :tsvector
      add_column :proc_guarded_article_documents, :content_vector, :tsvector
      add_index :proc_guarded_article_documents, :title_vector, using: :gin
      add_index :proc_guarded_article_documents, :content_vector, using: :gin
    when "sqlite"
      create_virtual_table :guarded_article_documents_fts, :fts5, [ "title", "content" ]
      create_virtual_table :unless_guarded_article_documents_fts, :fts5, [ "title", "content" ]
      create_virtual_table :proc_guarded_article_documents_fts, :fts5, [ "title", "content" ]
    end
  end
end
