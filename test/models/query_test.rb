require "test_helper"

class RelationTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  searches :articles

  setup do
    @article1 = Article.create!(title: "Ruby Programming", content: "Learn Ruby basics", account_id: 1)
    @article2 = Article.create!(title: "Python Programming", content: "Learn Python basics", account_id: 1)
    @article3 = Article.create!(title: "Ruby Advanced", content: "Advanced Ruby topics", account_id: 2)
    [ @article1, @article2, @article3 ].each { |r| ActiveSearch.index(:articles).add(r) }
  end

  test "limit restricts number of results" do
    results = ActiveSearch.index(:articles).search("Programming").limit(1).results

    assert_equal 1, results.to_a.size
  end

  test "offset skips results" do
    all_results = ActiveSearch.index(:articles).search("Ruby").results.to_a
    offset_results = ActiveSearch.index(:articles).search("Ruby").offset(1).results.to_a

    assert_equal all_results.size - 1, offset_results.size
  end

  test "limit and offset chain together" do
    results = ActiveSearch.index(:articles).search("Ruby").limit(1).offset(1).results

    assert_equal 1, results.to_a.size
  end

  test "results is not memoized" do
    relation = ActiveSearch.index(:articles).search("Ruby")

    results1 = relation.results
    results2 = relation.results

    refute_same results1, results2
  end

  test "to_native_query returns store-specific query" do
    relation = ActiveSearch.index(:articles).search("Ruby").filter(account_id: 1)
    raw_query = relation.to_native_query

    assert raw_query, "to_native_query should return a query object"
  end

  test "native modifies query before execution" do
    relation = ActiveSearch.index(:articles).search("Ruby")

    modified = false
    new_relation = relation.native { |q| modified = true; q }

    refute modified

    new_relation.results
    assert modified
  end

  test "native raises without block" do
    relation = ActiveSearch.index(:articles).search("Ruby")

    assert_raises(ActiveSearch::QueryError) do
      relation.native
    end
  end

  test "chaining creates new relations (immutability)" do
    base = ActiveSearch.index(:articles).search("Ruby")
    with_limit = base.limit(1)
    with_offset = base.offset(1)

    assert_equal 2, base.results.to_a.size

    assert_equal 1, with_limit.results.to_a.size
    assert_equal 1, with_offset.results.to_a.size
  end

  test "filter can be chained" do
    results = ActiveSearch.index(:articles).search("Ruby").filter(account_id: 1).results.to_a

    assert_equal 1, results.size
    assert_equal @article1.id, results.first.id
  end

  test "highlight can be chained" do
    skip "Store does not support highlighting" unless supports_highlighting?

    results = ActiveSearch.index(:articles).search("Ruby").highlight(true).results
    assert_match(/<mark>Ruby<\/mark>/, results.first.hit.highlight(:title))
  end

  test "sort can be chained" do
    relation = ActiveSearch.index(:articles).search("Ruby").sort(published_at: :asc)

    assert_equal [ { published_at: :asc } ], query_context_for(relation).sort
  end

  test "can start chain with filter" do
    results = ActiveSearch.index(:articles).filter(account_id: 1).search("Ruby").results.to_a

    assert_equal 1, results.size
  end

  test "can start chain with highlight" do
    skip "Store does not support highlighting" unless supports_highlighting?

    results = ActiveSearch.index(:articles).highlight(true).search("Ruby").results
    assert_match(/<mark>Ruby<\/mark>/, results.first.hit.highlight(:title))
  end

  test "search with nil query returns all documents" do
    results = ActiveSearch.index(:articles).search(nil).results

    assert_equal 3, results.total
  end

  test "search with empty string returns all documents" do
    results = ActiveSearch.index(:articles).search("").results

    assert_equal 3, results.total
  end

  test "search with single field restricts search" do
    results = ActiveSearch.index(:articles).search("Python", fields: :title).results

    assert_equal 1, results.total
    assert_equal @article2.id, results.first.id
  end

  test "search with array of fields restricts search" do
    results = ActiveSearch.index(:articles).search("Ruby", fields: [ :title, :content ]).results

    assert_equal 2, results.total
    assert_includes results.map(&:id), @article1.id
    assert_includes results.map(&:id), @article3.id
  end

  test "filter with empty hash is ignored" do
    results = ActiveSearch.index(:articles).search("Ruby").filter({}).results

    assert_equal 2, results.total
  end

  test "reject excludes matching documents" do
    results = ActiveSearch.index(:articles).search("Ruby").reject(account_id: 1).results

    assert_equal 1, results.total
    assert_equal @article3.id, results.first.id
  end

  test "reject with array excludes multiple values" do
    results = ActiveSearch.index(:articles).reject(account_id: [ 1, 2 ]).results

    assert_equal 0, results.total
  end

  test "multiple filter calls combine with AND" do
    article4 = Article.create!(title: "Ruby Extra", content: "More Ruby", account_id: 1)
    ActiveSearch.index(:articles).add(article4)

    results = ActiveSearch.index(:articles).search("Ruby").filter(account_id: 1).results

    assert_equal 2, results.total
    returned_ids = results.map(&:id)
    assert_includes returned_ids, @article1.id
    assert_includes returned_ids, article4.id
    refute_includes returned_ids, @article3.id  # account_id: 2, should be filtered out
  end

  test "filter with non-filterable field raises error" do
    assert_raises(ActiveSearch::QueryError) do
      ActiveSearch.index(:articles).filter(nonexistent_field: "value").results
    end
  end

  test "reject with non-filterable field raises error" do
    assert_raises(ActiveSearch::QueryError) do
      ActiveSearch.index(:articles).reject(nonexistent_field: "value").results
    end
  end

  test "filter accepts string field names" do
    results = ActiveSearch.index(:articles).search("Ruby").filter("account_id" => 1).results

    assert_equal 1, results.total
    assert_equal @article1.id, results.first.id
  end

  test "reject accepts string field names" do
    results = ActiveSearch.index(:articles).search("Ruby").reject("account_id" => 1).results

    assert_equal 1, results.total
    assert_equal @article3.id, results.first.id
  end

  test "sort with non-sortable field raises error" do
    assert_raises(ActiveSearch::QueryError) do
      ActiveSearch.index(:articles).search("Ruby").sort(:nonexistent_field).results
    end
  end

  test "an explicit direction changes the order" do
    asc_results = ActiveSearch.index(:articles).search("Ruby").sort(account_id: :asc).results.to_a
    desc_results = ActiveSearch.index(:articles).search("Ruby").sort(account_id: :desc).results.to_a

    assert_equal 2, asc_results.size
    assert_equal 2, desc_results.size

    refute_equal asc_results.map(&:id), desc_results.map(&:id),
      "Ascending and descending sort should produce different orders"
  end

  test "sort with Score constant sorts by relevance" do
    results = ActiveSearch.index(:articles).search("Ruby").sort_by_relevance.results

    assert_equal 2, results.total
  end

  test "sort with symbol is accepted" do
    results = ActiveSearch.index(:articles).search("Ruby").sort(:account_id).results

    assert_equal 2, results.total
  end

  test "limit with zero returns empty results" do
    results = ActiveSearch.index(:articles).search("Ruby").limit(0).results

    assert_equal 0, results.to_a.size
  end

  test "offset without a limit skips from the front and returns the rest" do
    results = ActiveSearch.index(:articles).search("Ruby").offset(1).results

    assert_equal 1, results.to_a.size
  end

  test "offset greater than total returns empty results" do
    results = ActiveSearch.index(:articles).search("Ruby").offset(100).results

    assert_equal 0, results.to_a.size
  end

  test "limit and offset with large values work" do
    limit = store_adapter_name == :typesense ? 200 : 1000
    results = ActiveSearch.index(:articles).search("Ruby").limit(limit).offset(0).results

    assert_equal 2, results.to_a.size
  end

  test "a filter applied before search still narrows the results" do
    results = ActiveSearch.index(:articles).filter(account_id: 1).search("Ruby").results

    assert_equal 1, results.total
  end

  test "a limit set before a filter does not stop the filter applying" do
    results = ActiveSearch.index(:articles).search("Ruby").limit(1).filter(account_id: 1).results

    assert_equal 1, results.to_a.size
    assert_equal 1, results.first.account_id
  end

  test "an offset set before a filter applies to the filtered results" do
    article4 = Article.create!(title: "Ruby Fourth", content: "More Ruby", account_id: 1)
    ActiveSearch.index(:articles).add(article4)

    all_results = ActiveSearch.index(:articles).search("Ruby").filter(account_id: 1).results
    assert_equal 2, all_results.total

    offset_results = ActiveSearch.index(:articles).search("Ruby").offset(1).filter(account_id: 1).results
    assert_equal 1, offset_results.to_a.size
  end

  test "sort before search works" do
    asc_results = ActiveSearch.index(:articles).sort(account_id: :asc).search("Ruby").results.to_a
    desc_results = ActiveSearch.index(:articles).sort(account_id: :desc).search("Ruby").results.to_a

    assert_equal 2, asc_results.size
    refute_equal asc_results.map(&:id), desc_results.map(&:id),
      "Sort before search should affect result order"
  end

  test "complex chain with all methods works" do
    results = ActiveSearch.index(:articles)
      .search("Ruby")
      .filter(account_id: 1)
      .sort(published_at: :desc)
      .limit(10)
      .offset(0)
      .results

    assert_equal 1, results.total
  end

  test "rejects invalid field names in search to prevent SQL injection" do
    assert_raises(ActiveSearch::QueryError) do
      ActiveSearch.index(:articles).search("foo", fields: [ "title); DROP TABLE --" ]).results
    end
  end

  test "rejects non-existent field names in search" do
    assert_raises(ActiveSearch::QueryError) do
      ActiveSearch.index(:articles).search("foo", fields: [ :nonexistent_field ]).results
    end
  end
end
