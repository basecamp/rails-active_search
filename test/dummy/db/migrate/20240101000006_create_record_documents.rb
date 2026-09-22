class CreateRecordDocuments < ActiveRecord::Migration[7.0]
  def change
    adapter = connection.adapter_name.downcase

    create_table :record_documents do |t|
      # The :records index is polymorphic, so a document is keyed by type and id together.
      t.string :record_type, null: false
      t.string :record_id, null: false
      t.text :title
      t.text :body
      t.bigint :account_id
    end

    add_index :record_documents, [ :record_type, :record_id ], unique: true

    case adapter
    when "mysql2"
      add_index :record_documents, [ :title, :body ], type: :fulltext
    when "postgresql"
      add_column :record_documents, :title_vector, :tsvector
      add_column :record_documents, :body_vector, :tsvector
      add_index :record_documents, :title_vector, using: :gin
      add_index :record_documents, :body_vector, using: :gin
    when "sqlite"
      create_virtual_table :record_documents_fts, :fts5, [ "title", "body" ]
    end
  end
end
