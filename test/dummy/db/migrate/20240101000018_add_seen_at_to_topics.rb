class AddSeenAtToTopics < ActiveRecord::Migration[7.0]
  def change
    collection = connection.adapter_name.downcase == "postgresql" ? :jsonb : :json

    add_column :topics, :seen_at, collection
    add_column :topic_documents, :seen_at, collection
  end
end
