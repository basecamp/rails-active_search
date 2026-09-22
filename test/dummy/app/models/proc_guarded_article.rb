class ProcGuardedArticle < ApplicationRecord
  include ActiveSearch::Indexable

  self.table_name = "proc_guarded_article"

  has_search index: :proc_guarded_articles,
                   add_if: ->(r) { r.status == "published" },
                   remove_if: ->(r) { r.status != "archived" },
                   async: false

  def to_search_document
    { title: title, content: content, status: status }
  end
end
