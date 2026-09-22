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
end
