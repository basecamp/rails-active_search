require "test_helper"

class PostgresqlTest < ActiveSupport::TestCase
  searches :articles

  setup do
    skip "PostgreSQL tests require SEARCH_ADAPTER=postgresql" unless store_adapter_name == :postgresql
  end

  test "snippet with 10 words returns a fragment from the match, not centered on it" do
    long_content = ("word " * 30) + "Ruby programming is great" + (" word" * 30)
    article = Article.create!(title: "Ruby Guide", content: long_content, account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").highlight(
      title: true,
      content: { snippet: { words: 10 } }
    ).results
    result = results.first

    assert_equal "<mark>Ruby</mark> Guide", result.hit.highlight(:title)
    assert_equal "<mark>Ruby</mark> programming is great word word word word word word", result.hit.highlight(:content)
  end

  test "snippet with 5 words returns fragment from match" do
    long_content = ("word " * 30) + "Ruby programming" + (" word" * 30)
    article = Article.create!(title: "The Complete Ruby Programming Guide for Beginners", content: long_content, account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").highlight(
      title: { snippet: { words: 5 } },
      content: { snippet: { words: 5 } }
    ).results
    result = results.first

    assert_equal "<mark>Ruby</mark> Programming Guide for Beginners", result.hit.highlight(:title)
    assert_equal "<mark>Ruby</mark> programming word word word", result.hit.highlight(:content)
  end

  test "snippet true uses default 20 words" do
    long_content = ("word " * 30) + "Ruby programming" + (" word" * 30)
    article = Article.create!(title: "Guide", content: long_content, account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").highlight(
      content: { snippet: true }
    ).results
    result = results.first

    assert_equal "<mark>Ruby</mark> programming word word word word word word word word word word word word word word word word word word", result.hit.highlight(:content)
  end

  test "raises on character-based snippet" do
    article = Article.create!(title: "Ruby Guide", content: "Ruby content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    assert_raises(ActiveSearch::UnsupportedOperationError) do
      ActiveSearch.index(:articles).search("Ruby").highlight(
        content: { snippet: { characters: 100 } }
      ).results
    end
  end

  test "stems with the english configuration by default" do
    article = Article.create!(title: "Running shoes", content: "Fast", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    assert_equal [ article.id ], ActiveSearch.index(:articles).search("run").results.map(&:id)
  end

  test "text_search_config sets the configuration for documents, queries and highlights" do
    with_text_search_config("simple") do
      article = Article.create!(title: "Running shoes", content: "Fast", account_id: 1)
      ActiveSearch.index(:articles).add(article)

      assert_empty ActiveSearch.index(:articles).search("run").results
      # english drops "the" as a stop word, so it would match everything and highlight nothing.
      result = ActiveSearch.index(:articles).search("running").highlight(title: true).results.first
      assert_equal article.id, result.id
      assert_equal "<mark>Running</mark> shoes", result.hit.highlight(:title)
    end
  end

  test "an unknown text_search_config raises from the database" do
    with_text_search_config("klingon") do
      article = Article.create!(title: "Ruby", content: "Guide", account_id: 1)

      assert_raises(ActiveSearch::Error) { ActiveSearch.index(:articles).add(article) }
    end
  end

  private
    def with_text_search_config(config)
      stores = ActiveSearch.configuration.instance_variable_get(:@stores)
      name = ActiveSearch.index(:articles).send(:configured_store_name)
      original = stores[name]
      stores[name] = ActiveSearch::StoreAdapters::Postgresql.new(text_search_config: config)
      yield
    ensure
      stores[name] = original
    end
end

class PostgresqlTextSearchConfigTest < ActiveSupport::TestCase
  test "defaults to english" do
    assert_equal "english", ActiveSearch::StoreAdapters::Postgresql.new.text_search_config
  end

  test "takes a string or a symbol and keeps it out of the client options" do
    store = ActiveSearch::StoreAdapters::Postgresql.new(text_search_config: :italian, max_result_window: 50)

    assert_equal "italian", store.text_search_config
    assert_equal({ max_result_window: 50 }, store.options)
  end

  test "rejects a value that cannot name a configuration" do
    [ "", "  ", 42, [ "english" ] ].each do |value|
      assert_raises(ActiveSearch::ConfigurationError, value.inspect) do
        ActiveSearch::StoreAdapters::Postgresql.new(text_search_config: value)
      end
    end
  end
end
