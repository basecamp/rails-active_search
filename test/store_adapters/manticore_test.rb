require "test_helper"

class ManticoreTest < ActiveSupport::TestCase
  searches :articles, :topics

  setup do
    skip "Manticore tests require SEARCH_ADAPTER=manticore" unless store_adapter_name == :manticore
  end

  # A multi-value attribute is a set, where every other adapter returns a collection as written.
  test "an integer collection is stored as an MVA, which sorts and deduplicates it" do
    ActiveSearch.index(:topics).tap do |index|
      topic = Topic.create!(subject: "Repeats", folder_ids: [ 3, 1, 3 ], labels: [], account_id: 1)
      index.add(topic)

      assert_equal [ 1, 3 ], index.search("Repeats").results.first.hit.fields[:folder_ids]
    end
  end

  # There is no multi_string, so a non-integer collection falls back to a json column.
  test "a string collection keeps its order and duplicates, being json rather than an MVA" do
    ActiveSearch.index(:topics).tap do |index|
      topic = Topic.create!(subject: "Tagged", folder_ids: [], labels: %w[b a b], account_id: 1)
      index.add(topic)

      assert_equal %w[b a b], index.search("Tagged").results.first.hit.fields[:labels]
    end
  end

  test "highlighting returns marked matches" do
    article = Article.create!(title: "Ruby Programming Guide", content: "Learn Ruby today", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").highlight(title: true, content: true).results
    result = results.first

    assert_equal "<mark>Ruby</mark> Programming Guide", result.hit.highlight(:title)
    assert_equal "Learn <mark>Ruby</mark> today", result.hit.highlight(:content)
  end

  test "highlighting with custom markers" do
    article = Article.create!(title: "Ruby Guide", content: "Learn Ruby", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    # Manticore takes one set of tags for every field, so both must ask for the same pair.
    results = ActiveSearch.index(:articles).search("Ruby").highlight(
      title: { markers: [ "<em>", "</em>" ] },
      content: { markers: [ "<em>", "</em>" ] }
    ).results
    result = results.first

    assert_equal "<em>Ruby</em> Guide", result.hit.highlight(:title)
    assert_equal "Learn <em>Ruby</em>", result.hit.highlight(:content)
  end

  # Manticore takes one limit for the whole query, so every field asks for the same snippet. The
  # size is below Manticore's own default, so a dropped limit cannot pass this.
  test "snippet with character limit" do
    long_content = ("word " * 50) + "Ruby programming" + (" word" * 50)
    article = Article.create!(title: "Ruby Guide", content: long_content, account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").highlight(
      title: { snippet: { characters: 20 } },
      content: { snippet: { characters: 20 } }
    ).results
    result = results.first

    assert_equal "<mark>Ruby</mark> Guide", result.hit.highlight(:title)
    assert_equal " <mark>Ruby</mark> programming", result.hit.highlight(:content)
  end

  test "raises on word-based snippet" do
    article = Article.create!(title: "Ruby Guide", content: "Ruby content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    assert_raises(ActiveSearch::UnsupportedOperationError) do
      ActiveSearch.index(:articles).search("Ruby").highlight(content: { snippet: { words: 10 } }).results
    end
  end

  test "client configuration with custom host and port" do
    store = ActiveSearch::StoreAdapters::Manticore.new(
      host: "custom-host",
      port: 9309
    )

    assert_instance_of Net::HTTP, store.http
  end

  test "returns relevance scores" do
    article1 = Article.create!(title: "Ruby", content: "Short", account_id: 1)
    article2 = Article.create!(title: "Ruby Ruby Ruby", content: "Ruby Ruby Ruby Ruby Ruby", account_id: 1)
    [ article1, article2 ].each { |r| ActiveSearch.index(:articles).add(r) }

    results = ActiveSearch.index(:articles).search("Ruby").results
    assert_equal 2, results.total

    scores = results.map { |r| r.hit.score }
    assert scores.all? { |s| s > 0 }, "All results should have positive scores"
  end

  test "ping returns true when connected" do
    index = ActiveSearch.index(:articles)
    assert index.store.ping
  end

  test "filter-only search without query text" do
    article1 = Article.create!(title: "Published", content: "Content", account_id: 1, status: "published")
    article2 = Article.create!(title: "Draft", content: "Content", account_id: 1, status: "draft")
    [ article1, article2 ].each { |r| ActiveSearch.index(:articles).add(r) }

    index = ActiveSearch.index(:articles)
    results = index.search("").filter(status: "published").results

    assert_equal 1, results.total
    assert_equal article1.id, results.first.id
  end

  test "highlights an entire matching phrase as one block, not word by word" do
    article = Article.create!(title: "Ruby Ruby Ruby", content: "Content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").highlight(true).results
    result = results.first

    assert_equal "<mark>Ruby Ruby Ruby</mark>", result.hit.highlight(:title)
  end

  test "to_native_query contains match clause for text search" do
    relation = ActiveSearch.index(:articles).search("Ruby")
    raw_query = relation.to_native_query

    assert_equal "articles", raw_query[:table]
    must_clauses = raw_query.dig(:query, :bool, :must)
    match_clause = must_clauses.find { |c| c[:match]&.values&.first == "Ruby" }
    assert_equal "Ruby", match_clause[:match].values.first
  end

  test "to_native_query contains equals filter" do
    relation = ActiveSearch.index(:articles).search("Ruby").filter(account_id: 42)
    raw_query = relation.to_native_query

    filter_clauses = raw_query.dig(:query, :bool, :filter)
    filter = filter_clauses.find { |f| f.dig(:equals, "account_id") }
    assert_equal 42, filter.dig(:equals, "account_id")
  end

  test "to_native_query respects limit and offset" do
    relation = ActiveSearch.index(:articles).search("Ruby").limit(5).offset(10)
    raw_query = relation.to_native_query

    assert_equal 5, raw_query[:limit]
    assert_equal 10, raw_query[:offset]
  end

  test "native can add custom options" do
    article = Article.create!(title: "Raw Modify", content: "Content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Raw Modify").native { |query| query[:limit] = 5; query }.results
    assert_equal 1, results.total
  end

  test "highlighting preserves HTML in original content" do
    article = Article.create!(title: "<b>Bold</b> Ruby", content: "Content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").highlight(title: true).results
    result = results.first

    assert_equal "&lt;b&gt;Bold&lt;/b&gt; <mark>Ruby</mark>", result.hit.highlight(:title)
  end

  # Manticore sends total_relation beside the total and answers "gte" once its count is capped.
  test "a capped total is reported as a lower bound" do
    store = ActiveSearch.index(:articles).store
    envelope = { "took" => 0, "timed_out" => false }

    capped = store.send(:parse_response,
      envelope.merge("hits" => { "total" => 20, "total_relation" => "gte", "hits" => [] }), nil, nil)
    counted = store.send(:parse_response,
      envelope.merge("hits" => { "total" => 3, "total_relation" => "eq", "hits" => [] }), nil, nil)

    assert_equal [ 20, :lower_bound ], capped.values_at(:total, :total_relation)
    assert_equal [ 3, :equal ], counted.values_at(:total, :total_relation)
  end

  test "a timed-out total is a lower bound even when the relation says eq" do
    store = ActiveSearch.index(:articles).store

    parsed = store.send(:parse_response,
      { "took" => 5, "timed_out" => true,
        "hits" => { "total" => 3, "total_relation" => "eq", "hits" => [] } }, nil, nil)

    assert_equal :lower_bound, parsed[:total_relation]
    assert_equal true, parsed[:partial_results]
  end

  # Net::HTTP does not raise for a non-2xx, so a 503 body that happens to parse reads as a result.
  test "a non-success status is an AdapterError rather than an empty result" do
    [ '{"message":"unavailable"}', "<html>gateway</html>" ].each do |body|
      with_response(code: "503", message: "Service Unavailable", body: body) do
        error = assert_raises(ActiveSearch::AdapterError) { ActiveSearch.index(:articles).search("x").results }
        assert_match(/503 Service Unavailable/, error.message)
      end
    end
  end

  # Both are Timeout::Errors, under none of the socket or protocol classes.
  test "a timeout is a declared client error" do
    declared = ActiveSearch.index(:articles).store.class::CLIENT_ERRORS

    [ Net::OpenTimeout, Net::ReadTimeout ].each do |timeout|
      assert declared.any? { |klass| timeout <= klass }, "#{timeout} is not covered by #{declared.inspect}"
    end
  end

  # Manticore reports a rejected query as a 200 with an error body, which must still reach a
  # caller as AdapterError like every other adapter's backend failure.
  test "a rejected request arrives as AdapterError" do
    query = ActiveSearch.index(:articles).search("anything").native do |body|
      body[:table] = "no_such_table"
      body
    end

    error = assert_raises(ActiveSearch::AdapterError) { query.results }
    assert_match(/Manticore rejected the request/, error.message)
  end

  # An error body wins over the status, because Manticore's own text says more than "500".
  test "an error body is reported even when the status also failed" do
    with_response(code: "500", message: "Internal Server Error", body: '{"error":"unknown table"}') do
      error = assert_raises(ActiveSearch::AdapterError) { ActiveSearch.index(:articles).search("x").results }
      assert_match(/Manticore rejected the request: unknown table/, error.message)
    end
  end

  # Manticore reads id 0 as auto-assign: the write lands under a server-picked id this adapter
  # could never delete or replace again.
  test "document id 0 is refused rather than stored unaddressably" do
    index = ActiveSearch.index(:articles)
    document = ActiveSearch::Document.new(id: "0", definition: index.definition,
      data: { title: "Zero", content: "Content", account_id: 1 })

    add_error = assert_raises(ActiveSearch::DocumentError) { index.store.add(index, document) }
    assert_match(/auto-assign/, add_error.message)

    assert_raises(ActiveSearch::DocumentError) { index.store.remove(index, "0") }
  end

  private
    def with_response(code:, message:, body:)
      store = ActiveSearch.index(:articles).store
      original = store.http
      response = Struct.new(:code, :message, :body).new(code, message, body)
      store.instance_variable_set(:@http, Struct.new(:reply).new(response).tap do |http|
        http.define_singleton_method(:request) { |_req| reply }
      end)

      yield
    ensure
      store.instance_variable_set(:@http, original)
    end
end
