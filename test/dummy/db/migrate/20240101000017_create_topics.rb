class CreateTopics < ActiveRecord::Migration[7.0]
  def change
    adapter = connection.adapter_name.downcase
    # Containment is asked of the column, so PostgreSQL needs jsonb rather than json: @> is a
    # jsonb operator and json has no equality to build one from.
    collection = adapter == "postgresql" ? :jsonb : :json

    create_table :topics do |t|
      t.string :subject
      t.bigint :account_id
      t.public_send collection, :folder_ids
      t.public_send collection, :labels
    end

    create_table :topic_documents do |t|
      t.string :topic_id, null: false
      t.text :subject
      t.bigint :account_id
      t.public_send collection, :folder_ids
      t.public_send collection, :labels
    end
    add_index :topic_documents, :topic_id, unique: true

    case adapter
    when "mysql2"
      add_index :topic_documents, [ :subject ], type: :fulltext
    when "postgresql"
      add_column :topic_documents, :subject_vector, :tsvector
      add_index :topic_documents, :subject_vector, using: :gin
    when "sqlite"
      create_virtual_table :topic_documents_fts, :fts5, [ "subject" ]
    end
  end
end
