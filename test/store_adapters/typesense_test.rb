require "test_helper"

class TypesenseTest < ActiveSupport::TestCase
  searches :articles

  setup do
    skip "Typesense tests require SEARCH_ADAPTER=typesense" unless store_adapter_name == :typesense
  end

  test "typo tolerance matches misspelled words" do
    article = Article.create!(title: "programming", content: "Content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("programing").results  # missing 'm'
    assert_equal 1, results.total
    assert_equal article.id, results.first.id
  end

  test "highlighting returns marked matches" do
    article = Article.create!(title: "Ruby Programming Guide", content: "Learn Ruby today", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").highlight(title: true, content: true).results
    result = results.first

    assert_equal "<mark>Ruby</mark> Programming Guide", result.hit.highlight(:title)
    assert_equal "Learn <mark>Ruby</mark> today", result.hit.highlight(:content)
  end

  test "client configuration" do
    store = ActiveSearch::StoreAdapters::Typesense.new(
      nodes: [ { host: "custom-host", port: 8108, protocol: "http" } ],
      api_key: "test_key"
    )

    assert_instance_of ::Typesense::Client, store.client
  end

  test "snippet with 10 words returns cropped content" do
    long_content = ("word " * 30) + "Ruby programming" + (" word" * 30)
    article = Article.create!(title: "Guide", content: long_content, account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").highlight(content: { snippet: { words: 10 } }).results
    result = results.first

    assert_equal "word word word word word <mark>Ruby</mark> programming word word word word", result.hit.highlight(:content)
  end

  test "raises on character-based snippet" do
    article = Article.create!(title: "Ruby Guide", content: "Ruby content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    assert_raises(ActiveSearch::UnsupportedOperationError) do
      ActiveSearch.index(:articles).search("Ruby").highlight(content: { snippet: { characters: 100 } }).results
    end
  end

  # The document stores fine; a backtick is ordinary data. Typesense honours no escape for one
  # inside its filter literal, so only the filter is refused.
  test "a filter value with a backtick is refused, not escaped" do
    article = Article.create!(title: "Test", content: "Content", account_id: 1, status: "test`quote")
    ActiveSearch.index(:articles).add(article)

    assert_raises(ActiveSearch::QueryError) do
      ActiveSearch.index(:articles).search("Test").filter(status: "test`quote").results
    end
  end

  test "filter values with special characters don't cause injection" do
    article1 = Article.create!(title: "Safe", content: "Content", account_id: 1, status: "published")
    article2 = Article.create!(title: "Other", content: "Content", account_id: 2, status: "draft")
    [ article1, article2 ].each { |r| ActiveSearch.index(:articles).add(r) }

    index = ActiveSearch.index(:articles)
    results = index.search("").filter(status: "published] && account_id:>0 && status:=[x").results
    assert_equal 0, results.total, "the escaped value must not reopen the filter clause"
  end

  test "array filter uses exact match not range" do
    article1 = Article.create!(title: "Draft", content: "Content", account_id: 1, status: "draft")
    article2 = Article.create!(title: "Published", content: "Content", account_id: 1, status: "published")
    article3 = Article.create!(title: "Archived", content: "Content", account_id: 1, status: "archived")
    [ article1, article2, article3 ].each { |r| ActiveSearch.index(:articles).add(r) }

    results = ActiveSearch.index(:articles).filter(status: %w[draft published]).results

    assert_equal 2, results.total
    returned_ids = results.map(&:id)
    assert_includes returned_ids, article1.id
    assert_includes returned_ids, article2.id
    refute_includes returned_ids, article3.id
  end

  test "a limit above the page cap is refused with the cap named" do
    article = Article.create!(title: "Capped", content: "Content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    error = assert_raises(ActiveSearch::UnsupportedOperationError) do
      ActiveSearch.index(:articles).search("Capped").limit(251).results
    end

    assert_match(/250/, error.message)
    assert_match(/251/, error.message)
  end

  test "the largest allowed page is served" do
    article = Article.create!(title: "Capped", content: "Content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    assert_results article, ActiveSearch.index(:articles).search("Capped").limit(250)
  end

  # Omitting highlight_fields does not suppress highlighting: Typesense defaults it to the
  # query_by fields, so silence has to be asked for as "none".
  test "a query without highlight comes back with no highlights from the engine" do
    article = Article.create!(title: "Ruby Guide", content: "Learn Ruby", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    raw = ActiveSearch.index(:articles).search("Ruby").to_native_query
    assert_equal "none", raw[:highlight_fields]

    hit = ActiveSearch.index(:articles).store.send(:collection, :articles).documents.search(raw)["hits"].first
    assert_equal [], Array(hit["highlights"])
    assert_empty hit["highlight"].to_h
  end

  test "a cut-off search reports its total as a lower bound" do
    store = ActiveSearch.index(:articles).store

    cutoff = store.send(:parse_response,
      { "found" => 3, "hits" => [], "search_cutoff" => true, "search_time_ms" => 9 }, nil, nil)
    complete = store.send(:parse_response,
      { "found" => 3, "hits" => [], "search_cutoff" => false, "search_time_ms" => 1 }, nil, nil)

    assert_equal [ :lower_bound, true ], cutoff.values_at(:total_relation, :partial_results)
    assert_equal [ :equal, false ], complete.values_at(:total_relation, :partial_results)
  end
end
