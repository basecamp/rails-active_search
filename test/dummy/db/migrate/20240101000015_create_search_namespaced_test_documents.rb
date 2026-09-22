class CreateSearchNamespacedTestDocuments < ActiveRecord::Migration[7.0]
  def change
    adapter = connection.adapter_name.downcase

    create_table :search_namespaced_test_documents do |t|
      t.string :article_id, null: false  # source_name from indexes :article
      t.text :title
      t.text :content
    end

    add_index :search_namespaced_test_documents, :article_id, unique: true

    case adapter
    when "mysql2"
      add_index :search_namespaced_test_documents, [ :title, :content ], type: :fulltext
      add_index :search_namespaced_test_documents, :title, type: :fulltext
      add_index :search_namespaced_test_documents, :content, type: :fulltext
    when "postgresql"
      add_column :search_namespaced_test_documents, :title_vector, :tsvector
      add_column :search_namespaced_test_documents, :content_vector, :tsvector
      add_index :search_namespaced_test_documents, :title_vector, using: :gin
      add_index :search_namespaced_test_documents, :content_vector, using: :gin
    when "sqlite"
      create_virtual_table :search_namespaced_test_documents_fts, :fts5, [ "title", "content" ]
    end
  end
end
