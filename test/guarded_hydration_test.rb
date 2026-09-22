require "test_helper"

class GuardedHydrationTest < ActiveSupport::TestCase
  searches :articles, :guarded_articles, :unless_guarded_articles

  test "a record the guards now reject is not returned, though the index still holds it" do
    article = GuardedArticle.create!(title: "Drifting", content: "content", should_index: true)
    refresh
    assert_results article, search, "control: indexed and returned while the guard passed"

    article.update_columns(should_index: false)
    refresh

    assert_equal 1, search.results.total, "the index still holds the document"
    assert_empty search.results.to_a, "but the scope excludes the record now"
    assert_equal 1, search.results.dropped, "and says so, rather than leaving a short page unexplained"
  end

  test "a rejected record leaves the total alone" do
    kept = GuardedArticle.create!(title: "Drifting", content: "content", should_index: true)
    dropped = GuardedArticle.create!(title: "Drifting too", content: "content", should_index: true)
    refresh
    dropped.update_columns(should_index: false)

    results = ActiveSearch.index(:guarded_articles).search("Drifting").results

    assert_equal 2, results.total
    assert_equal 1, results.size
    assert_equal [ kept.id ], results.map(&:id)
  end

  test "a write-time guard alone does not filter reads" do
    article = UnlessGuardedArticle.create!(title: "Drifting write guard", content: "content", skip_indexing: false)
    ActiveSearch.index(:unless_guarded_articles).store.refresh(:unless_guarded_articles) rescue nil

    article.update_columns(skip_indexing: true)

    results = ActiveSearch.index(:unless_guarded_articles).search("Drifting").results
    assert_equal [ article.id ], results.map(&:id),
      "unless: guards writes only, so the indexed record is still returned"
  end

  test "a model with no guard is unaffected" do
    article = Article.create!(title: "Unguarded", content: "content", account_id: 1)
    ActiveSearch.index(:articles).add(article)
    ActiveSearch.index(:articles).store.refresh(:articles) rescue nil

    assert_equal [ article.id ], ActiveSearch.index(:articles).search("Unguarded").results.map(&:id)
  end

  private
    def search
      ActiveSearch.index(:guarded_articles).search("Drifting")
    end

    def refresh
      ActiveSearch.index(:guarded_articles).store.refresh(:guarded_articles)
    rescue StandardError
      nil
    end
end
