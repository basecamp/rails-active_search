require "test_helper"

class SearchScopeTest < ActiveSupport::TestCase
  searches :articles, :guarded_articles

  def indexed(**attrs)
    Article.create!(**{ title: "Scoped", content: "content", account_id: 1 }.merge(attrs)).tap do |record|
      ActiveSearch.index(:articles).add(record)
    end
    ensure
      ActiveSearch.index(:articles).store.refresh(:articles) rescue nil
  end

  test "a query scope preloads, and the preload reaches the loaded record" do
    article = indexed
    Comment.suppress_indexing { Comment.create!(body: "c", account_id: 1, article_id: article.id) }

    plain = Article.search("Scoped").results.first
    preloaded = Article.search("Scoped", scope: Article.preload(:comments)).results.first

    assert_not plain.association(:comments).loaded?, "control: not loaded without a scope"
    assert_predicate preloaded.association(:comments), :loaded?
  end

  test "a query scope narrows, and the hits it excludes are counted rather than lost" do
    kept = indexed(status: "published")
    indexed(status: "draft")

    results = Article.search("Scoped", scope: Article.where(status: "published")).results

    assert_equal [ kept.id ], results.map(&:id)
    assert_equal 2, results.total, "total counts index hits, not what survived"
    assert_equal 1, results.dropped
  end

  test "a declared default reaches an index-rooted search" do
    dropped = GuardedArticle.create!(title: "Rooted", content: "c", should_index: true)
    ActiveSearch.index(:guarded_articles).store.refresh(:guarded_articles) rescue nil
    dropped.update_columns(should_index: false)

    assert_empty ActiveSearch.index(:guarded_articles).search("Rooted").results.to_a
  end

  test "a model default applies without the caller asking" do
    GuardedArticle.create!(title: "Default", content: "c", should_index: true)
    dropped = GuardedArticle.create!(title: "Default", content: "c", should_index: true)
    ActiveSearch.index(:guarded_articles).store.refresh(:guarded_articles) rescue nil
    dropped.update_columns(should_index: false)

    assert_equal 1, GuardedArticle.search("Default").results.size
  end

  test "a model default applies from the index entry point too" do
    dropped = GuardedArticle.create!(title: "Default", content: "c", should_index: true)
    ActiveSearch.index(:guarded_articles).store.refresh(:guarded_articles) rescue nil
    dropped.update_columns(should_index: false)

    assert_empty ActiveSearch.index(:guarded_articles).search("Default").results.to_a
  end

  test "a call site adding a preload keeps the default" do
    source = ActiveSearch.index(:guarded_articles).source
      .with_scope(GuardedArticle.preload(:anything))

    assert_includes source.scope.to_sql, "should_index"
    assert_equal [ :anything ], source.scope.preload_values
  end

  test "a declaration returning nothing is a mistake rather than an absence" do
    empty = ActiveSearch::Source::Record.new(name: :articles, index_name: :articles,
      source_class_name: "Article")
    empty.define_singleton_method(:declaration) { -> { nil } }

    assert_raises(ActiveSearch::QueryError) { empty.scope }
  end

  test "a declared default is checked the same way a query scope is" do
    bad = ActiveSearch::Source::Record.new(name: :articles, index_name: :articles,
      source_class_name: "Article", query_scope: nil)
    bad.define_singleton_method(:declaration) { -> { Comment.all } }

    error = assert_raises(ActiveSearch::QueryError) { bad.scope }

    assert_match(/loads Comment/, error.message)
  end

  test "a query scope does not change when the declared default is evaluated" do
    evaluated = []
    probe = Class.new(ActiveSearch::Source::Record) do
      define_method(:declaration) { -> { evaluated << :now; all } }
    end

    plain = probe.new(name: :articles, index_name: :articles, source_class_name: "Article")
    scoped = plain.with_scope(Article.preload(:comments))

    assert_empty evaluated, "building the scoped source must not evaluate it"
    scoped.scope
    assert_equal [ :now ], evaluated
  end

  test "a call site contradicting the default wins, which is Rails merge semantics" do
    kept = GuardedArticle.create!(title: "Contradict", content: "c", should_index: true)
    ActiveSearch.index(:guarded_articles).store.refresh(:guarded_articles) rescue nil
    kept.update_columns(should_index: false)

    results = GuardedArticle.search("Contradict",
      scope: GuardedArticle.where(should_index: false)).results

    assert_equal [ kept.id ], results.map(&:id), "the default was removed by the conflict"
  end

  test "unscope removes the default entirely" do
    kept = GuardedArticle.create!(title: "Unscoped", content: "c", should_index: true)
    ActiveSearch.index(:guarded_articles).store.refresh(:guarded_articles) rescue nil
    kept.update_columns(should_index: false)

    results = GuardedArticle.search("Unscoped", scope: GuardedArticle.unscope(:where)).results

    assert_equal [ kept.id ], results.map(&:id)
  end

  test "a relation on another model is refused, because nothing downstream checks the class" do
    error = assert_raises(ActiveSearch::QueryError) do
      Article.search("Scoped", scope: Comment.all)
    end

    assert_match(/loads Comment/, error.message)
  end

  test "a non-relation is refused" do
    assert_raises(ActiveSearch::QueryError) { Article.search("Scoped", scope: []) }
  end

  test "a scope belongs to the query that set it" do
    indexed(status: "published")
    indexed(status: "draft")

    scoped = Article.search("Scoped", scope: Article.where(status: "published"))

    assert_equal 1, scoped.results.size
    assert_equal 2, Article.search("Scoped").results.size, "the next query is unaffected"
  end

  test "a scope survives further chaining" do
    kept = indexed(status: "published", account_id: 7)
    indexed(status: "draft", account_id: 7)

    results = Article.search("Scoped", scope: Article.where(status: "published"))
      .filter(account_id: 7)
      .results

    assert_equal [ kept.id ], results.map(&:id)
  end

  test "an object that does not answer the source contract is refused" do
    assert_raises(ActiveSearch::QueryError) { Article.search("Scoped").with_source(Object.new) }
  end
end
