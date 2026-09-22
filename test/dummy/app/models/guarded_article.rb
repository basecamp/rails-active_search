class GuardedArticle < ApplicationRecord
  include ActiveSearch::Indexable

  self.table_name = "guarded_article"

  # scope: as well as if:, so a drifted record — indexed while it qualified, no longer qualifying,
  # not yet reindexed — is excluded by the hydration query rather than returned.
  has_search index: :guarded_articles, if: :should_index?, async: false,
    scope: -> { where(should_index: true) }

  private
    def should_index?
      should_index
    end
end
