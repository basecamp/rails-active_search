require "test_helper"

class ElasticsearchTest < ActiveSupport::TestCase
  searches :articles

  setup do
    skip "Elasticsearch tests require SEARCH_ADAPTER=elasticsearch" unless store_adapter_name == :elasticsearch
  end

  test "phrase search with quotes matches exact phrase" do
    article1 = Article.create!(title: "exact phrase match", content: "Content here", account_id: 1)
    article2 = Article.create!(title: "exact match phrase", content: "Content here", account_id: 1)

    [ article1, article2 ].each { |r| ActiveSearch.index(:articles).add(r) }

    results = ActiveSearch.index(:articles).search("exact phrase").results
    assert_equal 2, results.total, "unquoted, both orderings match"

    results = ActiveSearch.index(:articles).search('"exact phrase"').results
    assert_equal 1, results.total
    assert_equal article1.id, results.first.id
  end

  test "add indexes record via as_document" do
    article = Article.create!(title: "Add Test", content: "Content", account_id: 1)

    index = ActiveSearch.index(:articles)
    index.remove(article) rescue nil

    index.add(article)

    results = index.search("Add Test").results
    assert_equal 1, results.total
  end

  test "remove deletes record via address" do
    article = Article.create!(title: "Remove Test", content: "Content", account_id: 1)

    index = ActiveSearch.index(:articles)
    index.add(article)

    results = index.search("Remove Test").results
    assert_equal 1, results.total

    index.remove(article)

    results = index.search("Remove Test").results
    assert_equal 0, results.total
  end

  test "client_options are passed through to Elasticsearch client" do
    store = ActiveSearch::StoreAdapters::Elasticsearch.new(
      hosts: [ { host: "a.localhost", port: 29207 } ],
      client_options: {
        compression: true,
        retry_on_failure: 3
      }
    )

    transport_options = store.client.transport.instance_variable_get(:@options)
    assert_equal true, transport_options[:compression]
    assert_equal 3, transport_options[:retry_on_failure]
  end

  test "client_options with transport_options are passed through" do
    store = ActiveSearch::StoreAdapters::Elasticsearch.new(
      hosts: [ { host: "a.localhost", port: 29207 } ],
      client_options: {
        transport_options: {
          request: { timeout: 42 }
        }
      }
    )

    transport_options = store.client.transport.instance_variable_get(:@options)
    assert_equal 42, transport_options[:transport_options][:request][:timeout]
  end

  test "snippet with 100 characters returns fragment" do
    long_content = ("word " * 30) + "Ruby programming is great" + (" word" * 30)
    article = Article.create!(title: "Ruby Guide", content: long_content, account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").highlight(
      title: true,
      content: { snippet: { characters: 100 } }
    ).results
    result = results.first

    assert_equal "<mark>Ruby</mark> Guide", result.hit.highlight(:title)
    assert_equal "word word word word word word word word word word word word word word word word word word word word <mark>Ruby</mark>", result.hit.highlight(:content)
  end

  test "snippet with 50 characters returns shorter fragment" do
    long_content = ("word " * 30) + "Ruby programming" + (" word" * 30)
    article = Article.create!(title: "The Complete Ruby Programming Guide for Beginners", content: long_content, account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").highlight(
      title: { snippet: { characters: 50 } },
      content: { snippet: { characters: 50 } }
    ).results
    result = results.first

    assert_equal "The Complete <mark>Ruby</mark> Programming Guide for Beginners", result.hit.highlight(:title)
    assert_equal "word word word word word word word word word word <mark>Ruby</mark>", result.hit.highlight(:content)
  end

  test "snippet true uses default 140 characters" do
    long_content = ("word " * 30) + "Ruby programming" + (" word" * 30)
    article = Article.create!(title: "Guide", content: long_content, account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").highlight(
      content: { snippet: true }
    ).results
    result = results.first

    assert_equal "word word word word word word word word word word word word word word word word word word word word word word word word word word word word <mark>Ruby</mark>", result.hit.highlight(:content)
  end

  test "raises on word-based snippet" do
    article = Article.create!(title: "Ruby Guide", content: "Ruby content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    assert_raises(ActiveSearch::UnsupportedOperationError) do
      ActiveSearch.index(:articles).search("Ruby").highlight(
        content: { snippet: { words: 10 } }
      ).results
    end
  end

  test "to_native_query contains simple_query_string for text search" do
    relation = ActiveSearch.index(:articles).search("Ruby")
    raw_query = relation.to_native_query

    simple_query = raw_query.dig(:query, :bool, :must, :simple_query_string)
    assert_equal "Ruby", simple_query[:query]
    assert_includes simple_query[:fields], :title
    assert_includes simple_query[:fields], :content
  end

  test "to_native_query contains filter terms" do
    relation = ActiveSearch.index(:articles).search("Ruby").filter(account_id: 42)
    raw_query = relation.to_native_query

    filter = raw_query.dig(:query, :bool, :filter).find { |f| f.dig(:term, :account_id) }
    assert_equal 42, filter.dig(:term, :account_id)
  end

  test "to_native_query respects limit and offset" do
    relation = ActiveSearch.index(:articles).search("Ruby").limit(5).offset(10)
    raw_query = relation.to_native_query

    assert_equal 5, raw_query[:size]
    assert_equal 10, raw_query[:from]
  end

  test "native can add custom query clauses" do
    article = Article.create!(title: "Boost Test", content: "Content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Boost").native { |query| query[:size] = 5; query }.results
    assert_equal 1, results.total
  end

  # Stubbed: an index large enough to pass track_total_hits is too slow to build here.
  test "a capped total is reported as a lower bound rather than as an exact count" do
    store = ActiveSearch.index(:articles).store

    capped = store.send(:parse_response, response_with_total(10_000, "gte"), nil, nil)
    counted = store.send(:parse_response, response_with_total(42, "eq"), nil, nil)
    truncated = store.send(:parse_response, response_with_total(2, "eq").merge("terminated_early" => true), nil, nil)

    assert_equal [ 10_000, :lower_bound ], capped.values_at(:total, :total_relation)
    assert_equal [ 42, :equal ], counted.values_at(:total, :total_relation)
    assert_equal [ 2, :lower_bound ], truncated.values_at(:total, :total_relation)
  end

  def response_with_total(value, relation)
    { "hits" => { "total" => { "value" => value, "relation" => relation }, "hits" => [] } }
  end

  # Stubbed: a three-document search finishes before a timeout is checked, and a single-shard
  # failure fails the whole query. Early termination is produced live below.
  PARTIAL_CASES = {
    "a timeout" => { "timed_out" => true, "_shards" => { "failed" => 0 }, "terminated_early" => false },
    "a failed shard" => { "timed_out" => false, "_shards" => { "failed" => 1 }, "terminated_early" => false },
    "early termination" => { "timed_out" => false, "_shards" => { "failed" => 0 }, "terminated_early" => true },
    "all three" => { "timed_out" => true, "_shards" => { "failed" => 2 }, "terminated_early" => true }
  }.freeze

  COMPLETE_CASES = {
    "a clean response" => { "timed_out" => false, "_shards" => { "failed" => 0 }, "terminated_early" => false }
  }.freeze

  test "an answer smaller than the query described is reported as partial" do
    store = ActiveSearch.index(:articles).store

    PARTIAL_CASES.each do |name, envelope|
      parsed = store.send(:parse_response, response_with(envelope), nil, nil)
      assert_equal true, parsed[:partial_results], "#{name} must be partial"
    end

    COMPLETE_CASES.each do |name, envelope|
      parsed = store.send(:parse_response, response_with(envelope), nil, nil)
      assert_equal false, parsed[:partial_results], "#{name} must not be partial"
    end
  end

  test "the store metrics say which condition made a page partial" do
    store = ActiveSearch.index(:articles).store
    parsed = store.send(:parse_response, response_with(PARTIAL_CASES.fetch("all three")), nil, nil)

    assert_equal 2, parsed[:store_metrics][:shards_failed]
    assert_equal true, parsed[:store_metrics][:timed_out]
    assert_equal true, parsed[:store_metrics][:terminated_early]
  end

  test "an early-terminated search reports a partial page on any server version" do
    5.times { |i| ActiveSearch.index(:articles).add(Article.create!(title: "Stopped #{i}", content: "stopped", account_id: 1)) }
    ActiveSearch.index(:articles).store.refresh(:articles)

    complete = ActiveSearch.index(:articles).search("stopped").results
    truncated = ActiveSearch.index(:articles).search("stopped").native { |q| q[:terminate_after] = 2; q }.results

    assert_not_predicate complete, :partial?
    assert_equal 5, complete.total

    assert_predicate truncated, :partial?, "terminate_after truncated the answer and Results lost it"
    assert_equal 2, truncated.size

    assert_not_predicate truncated, :total_exact?,
      "7.x sends the truncated count as \"eq\", which would publish 2 matches for a search that matched 5"
    assert_predicate complete, :total_exact?
  end

  # Elasticsearch answers under whichever representation matched, and require_field_match leaves
  # the bare name empty when that was a subfield. Stubbed: the schema cannot declare subfields yet.
  OPEN = ActiveSearch::Highlighting::STORE_OPEN_MARKER
  CLOSE = ActiveSearch::Highlighting::STORE_CLOSE_MARKER

  HIGHLIGHT_CASES = {
    "the bare field answers" =>
      [ :address, { "address" => [ "#{OPEN}fvldlaw#{CLOSE}.com" ] }, "<mark>fvldlaw</mark>.com" ],
    "a subfield answers" =>
      [ :address, { "address.prefix" => [ "#{OPEN}fvldlaw#{CLOSE}.com" ] }, "<mark>fvldlaw</mark>.com" ],
    "a wildcard was requested" =>
      [ :"address.*", { "address.prefix" => [ "#{OPEN}fvldlaw#{CLOSE}.com" ] }, "<mark>fvldlaw</mark>.com" ],
    "the bare field wins over a subfield" =>
      [ :address, { "address" => [ "#{OPEN}bare#{CLOSE}" ], "address.prefix" => [ "#{OPEN}sub#{CLOSE}" ] },
        "<mark>bare</mark>" ],
    "nothing answers" => [ :address, {}, nil ],
    "a different field answers" =>
      [ :address, { "note.prefix" => [ "#{OPEN}fvldlaw#{CLOSE}" ] }, nil ],
    "a longer name is not a subfield of a shorter one" =>
      [ :address, { "address_sort" => [ "#{OPEN}fvldlaw#{CLOSE}" ] }, nil ]
  }.freeze

  test "a highlight is read from the key the response used, under the name that was asked for" do
    store = ActiveSearch.index(:articles).store
    opts = ActiveSearch::Highlighting::Options.new(true)

    HIGHLIGHT_CASES.each do |name, (requested, raw, expected)|
      parsed = store.send(:parse_response, response_with_highlight(raw), opts, [ requested ])

      actual = parsed[:results].first[:highlights][:address]

      expected ? assert_equal(expected, actual, name) : assert_nil(actual, name)
    end
  end

  test "documents that failed inside a successful bulk request are reported" do
    store = ActiveSearch.index(:articles).store
    response = { "errors" => true, "items" => [
      { "index" => { "_id" => "1", "status" => 201 } },
      { "index" => { "_id" => "2", "status" => 400,
                     "error" => { "reason" => "failed to parse field [account_id]" } } }
    ] }

    error = assert_raises(ActiveSearch::AdapterError) { store.send(:raise_on_bulk_failures, response) }

    assert_match(/1 of 2 documents failed/, error.message)
    assert_match(/2: failed to parse field/, error.message)
  end

  test "a bulk response wrapped in a body object is read the same way" do
    store = ActiveSearch.index(:articles).store
    wrapped = Struct.new(:body).new({ "errors" => false, "items" => [] })

    assert_equal wrapped, store.send(:raise_on_bulk_failures, wrapped)
  end

  test "a partial bulk failure raises and keeps the buffer, so the caller can retry the flush" do
    index = ActiveSearch.index(:articles)
    article = Article.create!(title: "Bulk", content: "body", account_id: 1)
    failing = Class.new do
      def bulk(**)
        { "errors" => true,
          "items" => [ { "index" => { "_id" => "1", "status" => 400,
                                      "error" => { "reason" => "mapper_parsing_exception" } } } ] }
      end
    end.new

    store = index.store
    real = store.instance_variable_get(:@client)
    batch = index.batch

    batch.add(article)
    batch.flush

    begin
      store.instance_variable_set(:@client, failing)
      batch.add(article)

      assert_raises(ActiveSearch::PartialWriteError) { batch.flush }
      assert_equal 1, batch.size

      store.instance_variable_set(:@client, real)
      batch.flush
      assert_equal 0, batch.size, "an add is an id-keyed upsert, so the retried flush is safe"
    ensure
      store.instance_variable_set(:@client, real)
    end
  end

  test "a batch that never reached the store keeps its operations" do
    index = ActiveSearch.index(:articles)
    article = Article.create!(title: "Unsent", content: "body", account_id: 1)
    refusing = Class.new do
      def bulk(**) = raise(IOError, "connection reset")
    end.new

    store = index.store
    real = store.instance_variable_get(:@client)
    begin
      store.instance_variable_set(:@client, refusing)
      batch = index.batch
      batch.add(article)

      assert_raises(IOError) { batch.flush }
      assert_equal 1, batch.size
    ensure
      store.instance_variable_set(:@client, real)
    end
  end

  test "the extra hit does not push a request past the store's paging window" do
    article = Article.create!(title: "Windowed", content: "body", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    edge = ActiveSearch.index(:articles).search("Windowed").limit(50).offset(10_000 - 50)

    assert_equal 0, edge.results.size
    assert_not edge.results.next_page?, "nothing is reachable past the window, so there is no next page"
  end

  test "the extra hit is still fetched with room to spare" do
    store = ActiveSearch.index(:articles).store
    window = ActiveSearch.index(:articles).capabilities.max_result_window

    inside = ActiveSearch.index(:articles).search("x").limit(50).offset(window - 51)
    edge = ActiveSearch.index(:articles).search("x").limit(50).offset(window - 50)

    assert store.send(:fetch_one_extra?, query_context_for(inside))
    assert_not store.send(:fetch_one_extra?, query_context_for(edge))
  end

  def response_with_highlight(raw_highlights)
    {
      "hits" => {
        "total" => { "value" => 1, "relation" => "eq" },
        "hits" => [ { "_id" => "1", "_score" => 1.0, "_source" => { "address" => "fvldlaw.com" },
                      "highlight" => raw_highlights } ]
      }
    }
  end

  def response_with(envelope)
    envelope.merge("took" => 3, "hits" => { "total" => { "value" => 5, "relation" => "eq" }, "hits" => [] })
  end

  test "a partial answer never reports an exact total, though Elasticsearch marks it eq" do
    store = ActiveSearch.index(:articles).store

    PARTIAL_CASES.each do |name, envelope|
      parsed = store.send(:parse_response, response_with(envelope), nil, nil)
      assert_equal :lower_bound, parsed[:total_relation], "#{name} must not report an exact total"
    end

    complete = store.send(:parse_response, response_with(COMPLETE_CASES.fetch("a clean response")), nil, nil)
    assert_equal :equal, complete[:total_relation]
  end

  test "a declared string :id survives the round trip beside Elasticsearch's own _id" do
    index = ActiveSearch.define_index(:es_id_probe, source: "Article") do
      text :title
      string :id
    end
    store = index.store
    store.create_index(index)

    article = Article.create!(title: "IdProbeRoundTrip", content: "body", account_id: 1)
    store.add(index, ActiveSearch::Document.new(id: article.id.to_s, definition: index.definition,
      data: { title: "IdProbeRoundTrip", id: article.id.to_s }))
    store.refresh(index.index_name)

    query = index.search("IdProbeRoundTrip").hit_fields(:id, :title)
    assert_includes query.to_native_query[:_source], "id"

    assert_equal article.id.to_s, query.results.first.hit.fields[:id],
      "the declared id must arrive as a hit field, not be dropped for the store's _id"
  ensure
    store.drop_index(index) rescue nil
    ActiveSearch.configuration.unregister_index(:es_id_probe)
  end
end
