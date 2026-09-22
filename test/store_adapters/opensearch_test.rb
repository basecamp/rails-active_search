require "test_helper"

class OpensearchTest < ActiveSupport::TestCase
  searches :articles

  setup do
    skip "OpenSearch tests require SEARCH_ADAPTER=opensearch" unless store_adapter_name == :opensearch
  end

  test "native can set phrase matching" do
    article1 = Article.create!(title: "exact phrase match", content: "Content here", account_id: 1)
    article2 = Article.create!(title: "exact match phrase", content: "Content here", account_id: 1)

    [ article1, article2 ].each { |r| ActiveSearch.index(:articles).add(r) }

    results = ActiveSearch.index(:articles).search("exact phrase").results
    assert_equal 2, results.total

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

  test "client_options are passed through to OpenSearch client" do
    store = ActiveSearch::StoreAdapters::Opensearch.new(
      hosts: [ { host: "a.localhost", port: 29207 } ],
      client_options: {
        retry_on_failure: 3
      }
    )

    transport_options = store.client.transport.instance_variable_get(:@options)
    assert_equal 3, transport_options[:retry_on_failure]
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

  test "raises on word-based snippet" do
    article = Article.create!(title: "Ruby Guide", content: "Ruby content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    assert_raises(ActiveSearch::UnsupportedOperationError) do
      ActiveSearch.index(:articles).search("Ruby").highlight(
        content: { snippet: { words: 10 } }
      ).results
    end
  end
end
