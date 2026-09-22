class Comment < ApplicationRecord
  include ActiveSearch::Indexable

  has_search async: false, default: true
  has_search index: :records, async: false, serializer: :to_content_document,
    scope: -> { where.not(body: nil) }

  def to_content_document
    { title: "Comment", body: body, account_id: account_id }
  end
end
