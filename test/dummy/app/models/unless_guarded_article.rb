class UnlessGuardedArticle < ApplicationRecord
  include ActiveSearch::Indexable

  self.table_name = "unless_guarded_article"

  has_search index: :unless_guarded_articles, unless: :skip_indexing?, async: false

  def skip_indexing?
    skip_indexing
  end
end
