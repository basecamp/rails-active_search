require "test_helper"

class SolrTest < ActiveSupport::TestCase
  searches :articles

  setup do
    skip "Solr tests require SEARCH_ADAPTER=solr" unless store_adapter_name == :solr
  end

  test "highlighting returns marked matches" do
    article = Article.create!(title: "Ruby Programming Guide", content: "Learn Ruby today", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").highlight(title: true, content: true).results
    result = results.first

    assert_equal "<mark>Ruby</mark> Programming Guide", result.hit.highlight(:title)
    assert_equal "Learn <mark>Ruby</mark> today", result.hit.highlight(:content)
  end

  test "snippet with 80 characters returns truncated fragment" do
    long_content = ("word " * 30) + "Ruby programming is great" + (" word" * 30)
    article = Article.create!(title: "Ruby Guide", content: long_content, account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").highlight(
      title: true,
      content: { snippet: { characters: 80 } }
    ).results
    result = results.first

    assert_equal "<mark>Ruby</mark> Guide", result.hit.highlight(:title)
    content_snippet = result.hit.highlight(:content)
    assert content_snippet.include?("<mark>Ruby</mark>")
    assert content_snippet.length < long_content.length
  end

  test "a whole-field highlight beside a snippet field comes back whole" do
    long_title = "The Complete And Unabridged Ruby Programming Reference Manual " \
      "For Beginners Intermediates And Experts Covering Every Corner Of The Language " \
      "In Exhaustive And Exhausting Detail Across Many Chapters"
    article = Article.create!(title: long_title, content: ("word " * 30) + "Ruby is great" + (" word" * 30), account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").highlight(
      title: true,
      content: { snippet: { characters: 80 } }
    ).results
    result = results.first

    assert_equal long_title.sub("Ruby", "<mark>Ruby</mark>"), result.hit.highlight(:title)
    assert_operator result.hit.highlight(:content).length, :<, 200
  end

  test "each field honors its own snippet size" do
    long_title = "The Complete Ruby Programming Reference " + ("pad " * 30)
    long_content = ("word " * 40) + "Ruby programming is great" + (" word" * 40)
    article = Article.create!(title: long_title, content: long_content, account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").highlight(
      title: { snippet: { characters: 40 } },
      content: { snippet: { characters: 120 } }
    ).results
    title_fragment = results.first.hit.highlight(:title)
    content_fragment = results.first.hit.highlight(:content)

    assert_includes title_fragment, "<mark>Ruby</mark>"
    assert_includes content_fragment, "<mark>Ruby</mark>"
    assert_operator title_fragment.length, :<=, 80
    assert_operator content_fragment.length, :>, 80
    assert_operator content_fragment.length, :<=, 200
  end

  test "snippet true uses default 140 characters" do
    long_content = ("word " * 50) + "Ruby programming" + (" word" * 50)
    article = Article.create!(title: "Guide", content: long_content, account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").highlight(
      content: { snippet: true }
    ).results
    result = results.first

    content_snippet = result.hit.highlight(:content)
    assert content_snippet.include?("<mark>Ruby</mark>")
    assert content_snippet.length < long_content.length
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

  test "to_native_query sends user text through edismax without fielded searches" do
    relation = ActiveSearch.index(:articles).search("Ruby")
    raw_query = relation.to_native_query

    assert_equal "{!edismax v=$uq}", raw_query[:q]
    assert_equal "Ruby", raw_query[:uq]
    assert_equal "title content", raw_query[:qf]
    assert_equal "-*", raw_query[:uf]
  end

  test "to_native_query contains filter queries" do
    relation = ActiveSearch.index(:articles).search("Ruby").filter(account_id: 42)
    raw_query = relation.to_native_query

    assert raw_query[:fq].any? { |fq| fq.include?("account_id:42") }
  end

  test "to_native_query respects limit and offset" do
    relation = ActiveSearch.index(:articles).search("Ruby").limit(5).offset(10)
    raw_query = relation.to_native_query

    assert_equal 5, raw_query[:rows]
    assert_equal 10, raw_query[:start]
  end

  test "native can add custom parameters" do
    article = Article.create!(title: "Raw Solr Test", content: "Content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Raw Solr").native { |query| query[:rows] = 5; query }.results
    assert_equal 1, results.total
  end

  test "client configuration with custom url" do
    store = ActiveSearch::StoreAdapters::Solr.new(
      url: "http://custom-host:8983/solr"
    )

    client = store.client(:test_config)
    assert_instance_of RSolr::Client, client
    assert_equal "http://custom-host:8983/solr/test_config/", client.uri.to_s
  end

  test "escapes special characters in query" do
    article = Article.create!(title: "C++ Programming", content: "Learn C++ today", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("C++").results
    assert_equal 1, results.total, "+ is a Solr operator and must not parse as one"
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
    results = index.search("").filter(status: 'published" OR *:*').results
    assert_equal 0, results.total, "the escaped value must not reopen the filter clause"
  end


  # Query parsing rejects a bare "2026-09-16" where a write accepts and normalises one, so both
  # sides send the instant. The *_dt dynamic rule maps to pdate, so the probe mutates no schema.
  test "a Ruby Date is written and filtered as a DatePointField instant" do
    probe = ActiveSearch.define_index(:solr_date_probe, source: "Article") do
      text :title
      date :due_dt
    end
    def probe.index_name = :articles

    store = ActiveSearch.index(:articles).store
    store.reset_schema_cache
    document = ActiveSearch::Document.new(id: "Article/990",
      data: { title: "Dated", due_dt: Date.new(2026, 9, 16) }, definition: probe.definition)
    store.add(probe, document)
    store.soft_commit(:articles)

    assert_equal 1, probe.all.filter(due_dt: Date.new(2026, 9, 16)).results.total
    assert_equal 0, probe.all.filter(due_dt: Date.new(2026, 9, 17)).results.total
  ensure
    ActiveSearch.configuration.unregister_index(:solr_date_probe)
    store&.reset_schema_cache
  end

  # timeAllowed=0 makes Solr exceed its own limit at once and return what it had.
  test "an incomplete page is reported as partial results" do
    3.times { |i| ActiveSearch.index(:articles).add(Article.create!(title: "Cut #{i}", content: "cut", account_id: 1)) }
    ActiveSearch.index(:articles).store.refresh(:articles) rescue nil

    complete = ActiveSearch.index(:articles).search("cut")
    cut_off = ActiveSearch.index(:articles).search("cut").native { |params| params[:timeAllowed] = 0; params }

    assert_not_predicate complete.results, :partial?
    assert_predicate cut_off.results, :partial?, "Solr reported partialResults and Results lost it"

    assert_equal false, payload_for(complete)[:partial_results]
    assert_equal true, payload_for(cut_off)[:partial_results], "the payload lost it"

    assert_predicate complete.results, :total_exact?
    assert_not_predicate cut_off.results, :total_exact?
  end

  def payload_for(query)
    payload = nil
    callback = ->(*args) { payload = ActiveSupport::Notifications::Event.new(*args).payload }
    ActiveSupport::Notifications.subscribed(callback, "search.active_search") { query.results }
    payload
  end
end
