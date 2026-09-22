class Page < ApplicationRecord
  include ActiveSearch::Indexable

  has_search index: :records,
    serializer: ->(page) { { title: page.title, body: page.content, account_id: page.account_id } }
end
