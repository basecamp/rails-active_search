require "test_helper"

class RedisSearchTest < ActiveSupport::TestCase
  searches :articles, :topics

  setup do
    skip "Redis Search tests require SEARCH_ADAPTER=redis_search" unless store_adapter_name == :redis_search
  end

  # A collection is joined into one TAG value, and joining cannot tell [ "" ] from [].
  test "an empty string element cannot be told from an empty collection" do
    topic = Topic.create!(subject: "Blank", labels: [ "" ], folder_ids: [], account_id: 1)
    ActiveSearch.index(:topics).add(topic)

    assert_equal [], ActiveSearch.index(:topics).search("Blank").results.first.hit.fields[:labels]
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

    # Redis Search takes one set of tags for every field, so both must ask for the same pair.
    results = ActiveSearch.index(:articles).search("Ruby").highlight(
      title: { markers: [ "<em>", "</em>" ] },
      content: { markers: [ "<em>", "</em>" ] }
    ).results
    result = results.first

    assert_equal "<em>Ruby</em> Guide", result.hit.highlight(:title)
    assert_equal "Learn <em>Ruby</em>", result.hit.highlight(:content)
  end

  test "raises on snippet highlighting" do
    article = Article.create!(title: "Ruby Guide", content: "Ruby content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    assert_raises(ActiveSearch::UnsupportedOperationError) do
      ActiveSearch.index(:articles).search("Ruby").highlight(content: { snippet: true }).results
    end
  end

  test "raises on character-based snippet" do
    article = Article.create!(title: "Ruby Guide", content: "Ruby content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    assert_raises(ActiveSearch::UnsupportedOperationError) do
      ActiveSearch.index(:articles).search("Ruby").highlight(content: { snippet: { characters: 100 } }).results
    end
  end

  test "raises on word-based snippet" do
    article = Article.create!(title: "Ruby Guide", content: "Ruby content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    assert_raises(ActiveSearch::UnsupportedOperationError) do
      ActiveSearch.index(:articles).search("Ruby").highlight(content: { snippet: { words: 10 } }).results
    end
  end

  test "client configuration with custom host and port" do
    store = ActiveSearch::StoreAdapters::RedisSearch.new(
      host: "custom-host",
      port: 6380,
      db: 2
    )

    assert_instance_of Redis, store.client
  end

  test "escapes special characters in query without error" do
    article = Article.create!(title: "Programming Guide", content: "Learn today", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("++invalid++").results
    assert_equal 0, results.total, "+ is Redis Search's must-include operator and must not parse as one"

    results = ActiveSearch.index(:articles).search("Programming").results
    assert_equal 1, results.total
  end

  test "parentheses in a query are separators, not syntax and not part of the token" do
    article = Article.create!(title: "Function Guide", content: "Method invocation", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Function()").results
    assert_equal 1, results.total, "quoted, the punctuation splits the way the indexed text did"

    results = ActiveSearch.index(:articles).search("Function").results
    assert_equal 1, results.total
  end

  test "escapes at-sign in query without error" do
    article = Article.create!(title: "Email Contact", content: "Contact info", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("user@example").results
    assert_equal 0, results.total, "@ opens a field query in Redis Search and must not parse as one"

    results = ActiveSearch.index(:articles).search("Contact").results
    assert_equal 1, results.total
  end

  test "returns BM25 relevance scores" do
    article1 = Article.create!(title: "Ruby", content: "Short", account_id: 1)
    article2 = Article.create!(title: "Ruby Ruby Ruby", content: "Ruby Ruby Ruby Ruby Ruby", account_id: 1)
    [ article1, article2 ].each { |r| ActiveSearch.index(:articles).add(r) }

    results = ActiveSearch.index(:articles).search("Ruby").results
    assert_equal 2, results.total

    scores = results.map { |r| r.hit.score }
    assert scores.first > scores.last, "More relevant document should have higher score"
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

  test "filter values with special characters are escaped" do
    article = Article.create!(title: "Test", content: "Content", account_id: 1, status: "test|special")
    ActiveSearch.index(:articles).add(article)

    index = ActiveSearch.index(:articles)
    results = index.search("Test").filter(status: "test|special").results
    assert_equal 1, results.total
  end

  test "filter values with braces don't cause injection" do
    article1 = Article.create!(title: "Safe", content: "Content", account_id: 1, status: "published")
    article2 = Article.create!(title: "Other", content: "Content", account_id: 2, status: "draft")
    [ article1, article2 ].each { |r| ActiveSearch.index(:articles).add(r) }

    index = ActiveSearch.index(:articles)
    results = index.search("").filter(status: "published}|@account_id:[0 +inf]|{x").results
    assert_equal 0, results.total, "the escaped value must not reopen the filter clause"
  end

  test "multi-value numeric filter with proper scoping" do
    article1 = Article.create!(title: "First", content: "Content", account_id: 1, status: "published")
    article2 = Article.create!(title: "Second", content: "Content", account_id: 2, status: "published")
    article3 = Article.create!(title: "Third", content: "Content", account_id: 3, status: "draft")
    [ article1, article2, article3 ].each { |r| ActiveSearch.index(:articles).add(r) }

    results = ActiveSearch.index(:articles).filter(account_id: [ 1, 2 ]).filter(status: "published").results

    assert_equal 2, results.total
    returned_ids = results.map(&:id)
    assert_includes returned_ids, article1.id
    assert_includes returned_ids, article2.id
    refute_includes returned_ids, article3.id
  end

  test "phrase search preserves token order for negation" do
    article1 = Article.create!(title: "Hello world today", content: "Content", account_id: 1)
    article2 = Article.create!(title: "Hello there today", content: "Content", account_id: 1)
    [ article1, article2 ].each { |r| ActiveSearch.index(:articles).add(r) }

    results = ActiveSearch.index(:articles).search("Hello", fields: :title).results
    assert_equal 2, results.total, "control: both documents match the bare term"

    results = ActiveSearch.index(:articles).search('"Hello world"', fields: :title).results
    assert_equal 1, results.total
    assert_equal article1.id, results.first.id
  end

  # Redis Search indexes a NUMERIC field as a double, so two integers the gem stores intact are
  # one value to the index.
  test "an exact filter cannot separate two integers above 2**53" do
    index = ActiveSearch.index(:creation_probes)
    store = index.store
    a, b = 9_007_199_254_740_992, 9_007_199_254_740_993

    store.drop_index(index) rescue StandardError
    store.create_index(index)

    [ [ 1, a ], [ 2, b ] ].each do |id, account|
      store.write(index, ActiveSearch::Document.new(id: id,
        data: { title: "t#{id}", status: "s", account_id: account }, definition: index.definition))
    end

    client = store.send(:client)
    stored = [ 1, 2 ].map { |id| client.call("HGET", "creation_probes:#{id}", "account_id") }
    assert_equal [ a.to_s, b.to_s ], stored, "premise: both values are stored intact"

    answer = client.call("FT.SEARCH", "creation_probes", "@account_id:[#{a} #{a}]", "LIMIT", 0, 5)
    found = answer.is_a?(Hash) ? answer["total_results"] : answer.first

    assert_equal 2, found, "the index separated them, so this divergence is gone and the README is stale"
  ensure
    store.drop_index(index) rescue StandardError
  end

  test "a tag value with a space filters as one literal tag" do
    matching = Article.create!(title: "Spaced", content: "Content", account_id: 1, status: "in progress")
    Article.create!(title: "Spaced", content: "Content", account_id: 1, status: "in").tap { |r| ActiveSearch.index(:articles).add(r) }
    Article.create!(title: "Spaced", content: "Content", account_id: 1, status: "progress").tap { |r| ActiveSearch.index(:articles).add(r) }
    ActiveSearch.index(:articles).add(matching)

    assert_results matching, ActiveSearch.index(:articles).filter(status: "in progress")
  end

  test "a tag value with a slash filters literally" do
    matching = Article.create!(title: "Slashed", content: "Content", account_id: 1, status: "a/b path")
    Article.create!(title: "Slashed", content: "Content", account_id: 1, status: "a").tap { |r| ActiveSearch.index(:articles).add(r) }
    ActiveSearch.index(:articles).add(matching)

    assert_results matching, ActiveSearch.index(:articles).filter(status: "a/b path")
  end

  # FT.SEARCH HIGHLIGHT rewrites the returned attribute values, so the markers have to be stripped.
  test "highlighting leaves hit fields unmarked" do
    article = Article.create!(title: "Ruby Guide", content: "Learn Ruby today", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    result = ActiveSearch.index(:articles).search("Ruby").highlight(content: true).results.first

    assert_equal "Learn <mark>Ruby</mark> today", result.hit.highlight(:content)
    assert_equal "Learn Ruby today", result.hit.fields[:content]
    assert_equal "Ruby Guide", result.hit.fields[:title]
  end

  # Stubbed: a warning needs a query that outlives its TIMEOUT, which is not cheap to arrange.
  test "a RESP3 warning reports the page as partial" do
    store = ActiveSearch.index(:articles).store
    envelope = { "attributes" => [], "format" => "STRING", "results" => [], "total_results" => 0 }

    warned = store.send(:parse_response, envelope.merge("warning" => [ "Timeout limit was reached" ]), nil, nil, :articles)
    clean = store.send(:parse_response, envelope.merge("warning" => []), nil, nil, :articles)
    resp2 = store.send(:parse_response, [ 0 ], nil, nil, :articles)

    assert_equal [ true, :lower_bound ], warned.values_at(:partial_results, :total_relation)
    assert_equal [ false, :equal ], clean.values_at(:partial_results, :total_relation)
    assert_equal [ false, :equal ], resp2.values_at(:partial_results, :total_relation)
  end

  test "a stored literal marker survives in hit fields under highlighting" do
    article = Article.create!(title: "Ruby Guide", content: "Literal <mark>kept</mark> until Ruby matches", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    result = ActiveSearch.index(:articles).search("Ruby").highlight(content: true).results.first

    assert_equal "Literal <mark>kept</mark> until Ruby matches", result.hit.fields[:content]
  end
end
