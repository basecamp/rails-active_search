require "test_helper"

class DatabaseRelationTest < ActiveSupport::TestCase
  searches :articles

  setup do
    skip "relation tests require a database store" unless store.is_a?(ActiveSearch::StoreAdapters::Database)
  end

  test "raw returns ActiveRecord::Relation" do
    article = Article.create!(title: "Relation Test", content: "Content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    scope = ActiveSearch.index(:articles).search("Relation").to_native_query

    assert_kind_of ActiveRecord::Relation, scope
  end

  test "raw includes matching documents" do
    article1 = Article.create!(title: "Ruby Programming", content: "Learn Ruby", account_id: 1)
    article2 = Article.create!(title: "Python Programming", content: "Learn Python", account_id: 1)
    [ article1, article2 ].each { |r| ActiveSearch.index(:articles).add(r) }

    scope = ActiveSearch.index(:articles).search("Ruby").to_native_query

    ids = scope.map(&:article_id)
    assert_includes ids, article1.id.to_s
    refute_includes ids, article2.id.to_s
  end

  test "raw applies filters" do
    article1 = Article.create!(title: "Ruby One", content: "Content", account_id: 1)
    article2 = Article.create!(title: "Ruby Two", content: "Content", account_id: 2)
    [ article1, article2 ].each { |r| ActiveSearch.index(:articles).add(r) }

    scope = ActiveSearch.index(:articles).search("Ruby").filter(account_id: 1).to_native_query

    ids = scope.map(&:article_id)
    assert_includes ids, article1.id.to_s
    refute_includes ids, article2.id.to_s
  end

  test "raw applies sort" do
    old_time = 5.days.ago
    recent_time = 1.day.ago

    article1 = Article.create!(title: "Sortable One", content: "Content", account_id: 1, published_at: old_time)
    article2 = Article.create!(title: "Sortable Two", content: "Content", account_id: 1, published_at: recent_time)
    [ article1, article2 ].each { |r| ActiveSearch.index(:articles).add(r) }

    scope = ActiveSearch.index(:articles).search("Sortable").sort(published_at: :asc).to_native_query

    ids = scope.map(&:article_id)
    assert_equal [ article1.id.to_s, article2.id.to_s ], ids
  end

  test "raw can be merged with other scopes" do
    article1 = Article.create!(title: "Merge Test", content: "Content", account_id: 1)
    article2 = Article.create!(title: "Merge Test", content: "Content", account_id: 2)
    [ article1, article2 ].each { |r| ActiveSearch.index(:articles).add(r) }

    search_scope = ActiveSearch.index(:articles).search("Merge").filter(account_id: 1).to_native_query

    combined = Article.joins("INNER JOIN #{search_scope.model.table_name} ON #{search_scope.model.table_name}.article_id = articles.id::text")
      .merge(search_scope)

    assert_kind_of ActiveRecord::Relation, combined
  end

  test "raw includes score column" do
    article = Article.create!(title: "Score Test", content: "Content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    scope = ActiveSearch.index(:articles).search("Score").to_native_query

    row = scope.first
    assert row.score != 0, "Score should be non-zero for a match"
  end

  test "raw with empty query returns all documents" do
    article1 = Article.create!(title: "All One", content: "Content", account_id: 1)
    article2 = Article.create!(title: "All Two", content: "Content", account_id: 1)
    [ article1, article2 ].each { |r| ActiveSearch.index(:articles).add(r) }

    scope = ActiveSearch.index(:articles).search("").to_native_query

    assert_equal 2, scope.to_a.size
  end

  test "raw with highlight option includes highlight columns" do
    skip "Adapter does not support highlighting" unless supports_highlighting?

    article = Article.create!(title: "Highlight Relation", content: "Some content here", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    scope = ActiveSearch.index(:articles).search("Highlight").highlight(title: true).to_native_query

    row = scope.first
    assert_match(/Highlight/, row.title_hl)
  end
end
