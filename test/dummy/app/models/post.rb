class Post < ApplicationRecord
  include ActiveSearch::Indexable

  has_search index: :records, serializer: :to_content_document,
    scope: -> { where.not(headline: nil) }

  def to_content_document
    { title: headline, body: body, account_id: account_id }
  end
end
