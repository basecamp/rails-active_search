module Admin
  class Document < ApplicationRecord
    self.table_name = "admin_documents"

    include ActiveSearch::Indexable

    has_search index: :records, serializer: :to_content_document

    def to_content_document
      {
        title: title,
        body: body,
        account_id: account_id
      }
    end
  end
end
