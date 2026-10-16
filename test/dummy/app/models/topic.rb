class Topic < ApplicationRecord
  if connection.adapter_name.downcase == "sqlserver"
    serialize :folder_ids, coder: JSON, type: Array
    serialize :labels, coder: JSON, type: Array
    serialize :seen_at, coder: JSON, type: Array
  end

  has_search index: :topics
end
