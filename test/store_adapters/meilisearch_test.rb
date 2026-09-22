require "test_helper"

class MeilisearchTest < ActiveSupport::TestCase
  searches :articles

  setup do
    skip "Meilisearch tests require SEARCH_ADAPTER=meilisearch" unless store_adapter_name == :meilisearch
  end

  test "typo tolerance matches misspelled words" do
    article = Article.create!(title: "programming", content: "Content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("programing").results  # missing 'm'
    assert_equal 1, results.total
    assert_equal article.id, results.first.id
  end

  test "typo tolerance with multiple typos" do
    article = Article.create!(title: "elasticsearch", content: "Content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("elasticsearh").results  # missing 'c'
    assert_equal 1, results.total
  end

  test "highlighting returns marked matches" do
    article = Article.create!(title: "Ruby Programming Guide", content: "Learn Ruby today", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").highlight(title: true, content: true).results
    result = results.first

    assert_equal "<mark>Ruby</mark> Programming Guide", result.hit.highlight(:title)
    assert_equal "Learn <mark>Ruby</mark> today", result.hit.highlight(:content)
  end

  test "client url and api_key configuration" do
    store = ActiveSearch::StoreAdapters::Meilisearch.new(
      url: "http://custom-host:7700",
      api_key: "test_key"
    )

    assert_instance_of Meilisearch::Client, store.client
  end

  test "snippet with 10 words returns cropped content" do
    long_content = ("word " * 30) + "Ruby programming" + (" word" * 30)
    article = Article.create!(title: "Guide", content: long_content, account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").highlight(content: { snippet: { words: 10 } }).results
    result = results.first

    assert_equal "…word word word word word <mark>Ruby</mark> programming word word word…", result.hit.highlight(:content)
  end

  test "snippet true uses default 20 words" do
    long_content = ("word " * 30) + "Ruby programming" + (" word" * 30)
    article = Article.create!(title: "Guide", content: long_content, account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").highlight(content: { snippet: true }).results
    result = results.first

    assert_equal "…word word word word word word word word word word <mark>Ruby</mark> programming word word word word word word word word…", result.hit.highlight(:content)
  end

  test "two fields asking for different snippet sizes get both sizes" do
    article = Article.create!(title: long_text_matching_ruby(40), content: long_text_matching_ruby(60),
      account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").highlight(
      title: { snippet: { words: 4 } },
      content: { snippet: { words: 20 } }
    ).results
    hit = results.first.hit

    assert_equal 4, snippet_words(hit.highlight(:title))
    assert_equal 20, snippet_words(hit.highlight(:content))
  end

  test "one field whole beside another snippeted leaves the whole one uncropped" do
    article = Article.create!(title: long_text_matching_ruby(40), content: long_text_matching_ruby(60),
      account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").highlight(
      title: true,
      content: { snippet: { words: 6 } }
    ).results
    hit = results.first.hit

    assert_equal 40, snippet_words(hit.highlight(:title))
    assert_equal 6, snippet_words(hit.highlight(:content))
  end

  test "raises on character-based snippet" do
    article = Article.create!(title: "Ruby Guide", content: "Ruby content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    assert_raises(ActiveSearch::UnsupportedOperationError) do
      ActiveSearch.index(:articles).search("Ruby").highlight(content: { snippet: { characters: 100 } }).results
    end
  end

  test "filter values with quotes are escaped" do
    article = Article.create!(title: "Test", content: "Content", account_id: 1, status: 'test"quote')
    ActiveSearch.index(:articles).add(article)

    index = ActiveSearch.index(:articles)
    results = index.search("Test").filter(status: 'test"quote').results
    assert_equal 1, results.total
  end

  test "filter values with special characters don't cause injection" do
    article1 = Article.create!(title: "Safe", content: "Content", account_id: 1, status: "published")
    article2 = Article.create!(title: "Other", content: "Content", account_id: 2, status: "draft")
    [ article1, article2 ].each { |r| ActiveSearch.index(:articles).add(r) }

    index = ActiveSearch.index(:articles)
    results = index.search("").filter(status: 'published" OR account_id >= 0 OR status = "x').results
    assert_equal 0, results.total, "the escaped value must not reopen the filter clause"
  end

  test "a wait timeout is a declared client error" do
    declared = ActiveSearch.index(:articles).store.class::CLIENT_ERRORS

    assert declared.any? { |klass| ::Meilisearch::TimeoutError <= klass },
      "Meilisearch::TimeoutError is not covered by #{declared.inspect}"
  end

  test "encode_id emits only legal id characters and decodes back" do
    store = ActiveSearch.index(:articles).store

    [ "a.b c", "héllo:1/x", "--a-", "Article/123", "under_score9" ].each do |raw|
      encoded = store.send(:encode_id, raw)

      assert_match(/\A[A-Za-z0-9_-]+\z/, encoded, "#{raw.inspect} encoded to illegal #{encoded.inspect}")
      assert_equal raw, store.send(:decode_id, encoded)
    end
  end

  test "an empty document id is refused rather than sent" do
    error = assert_raises(ActiveSearch::DocumentError) do
      ActiveSearch.index(:articles).store.send(:encode_id, "")
    end

    assert_match(/non-empty/, error.message)
  end

  test "a query without highlight requests none" do
    raw = ActiveSearch.index(:articles).search("Ruby").to_native_query

    assert_nil raw[:params][:attributes_to_highlight]
  end

  # An unescaped dot or space is accepted at the write and fails the task later, which loses the
  # document silently until the next refresh.
  test "an id with dots and spaces survives the write and the read" do
    index = ActiveSearch.index(:articles)
    document = ActiveSearch::Document.new(id: "a.b c", definition: index.definition,
      data: { title: "Odd identifier", content: "Content", account_id: 7 })
    index.store.add(index, document)

    response = index.store.search(index, query_context_for(index.search("Odd").limit(10)), routing: nil)

    assert_equal [ "a.b c" ], response[:results].map { |hit| hit[:id] }
  end

  # Meilisearch reports estimatedTotalHits for a limit/offset search and totalHits only for
  # a page/hitsPerPage one, so which key comes back decides whether the count is exact.
  test "an estimated total is reported as an estimate rather than as an exact count" do
    store = ActiveSearch.index(:articles).store

    estimated = store.send(:parse_response, { "hits" => [], "estimatedTotalHits" => 980 }, nil, nil)
    counted = store.send(:parse_response, { "hits" => [], "totalHits" => 42 }, nil, nil)

    assert_equal [ 980, :estimate ], estimated.values_at(:total, :total_relation)
    assert_equal [ 42, :equal ], counted.values_at(:total, :total_relation)
  end

  private
    def long_text_matching_ruby(words)
      middle = words / 2
      ([ "word" ] * (middle - 1) + [ "Ruby" ] + [ "word" ] * (words - middle)).join(" ")
    end

    # Cropping leaves the marker glued to the edge word, so it is deleted rather than split off.
    def snippet_words(snippet)
      snippet.to_s.delete("…").gsub(/<[^>]*>/, "").split.size
    end
end
