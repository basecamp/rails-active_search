require "test_helper"

class SearchOptionsTest < ActiveSupport::TestCase
  searches :articles

  setup do
    @article1 = Article.create!(title: "Ruby Programming", content: "Learn Ruby basics", account_id: 1)
    @article2 = Article.create!(title: "Python Programming", content: "Learn Python basics", account_id: 1)
    @article3 = Article.create!(title: "Ruby Advanced Guide", content: "Advanced Ruby topics", account_id: 2)
    [ @article1, @article2, @article3 ].each { |r| ActiveSearch.index(:articles).add(r) }
  end

  test "operator: :and requires all terms to match" do
    skip "Store does not support operator" unless capabilities.supports_operator?

    results = ActiveSearch.index(:articles).search("Ruby Programming", operator: :and).results
    assert_equal 1, results.total
    assert_equal @article1.id, results.first.id
  end

  test "operator: :or matches any term" do
    skip "Store does not support operator" unless capabilities.supports_operator?

    results = ActiveSearch.index(:articles).search("Ruby Python", operator: :or).results
    assert_equal 3, results.total
  end

  test "operator defaults to engine default when not specified" do
    results = ActiveSearch.index(:articles).search("Ruby Programming").results

    ids = results.map(&:id)
    assert_includes ids, @article1.id
  end

  test "operator can be chained with filter" do
    skip "Store does not support operator" unless capabilities.supports_operator?

    results = ActiveSearch.index(:articles).search("Ruby Guide", operator: :and).filter(account_id: 2).results
    assert_equal 1, results.total
    assert_equal @article3.id, results.first.id
  end

  test "invalid operator raises QueryError" do
    assert_raises(ActiveSearch::QueryError) do
      ActiveSearch.index(:articles).search("Ruby", operator: :xor).results
    end
  end

  test "string operator is normalized" do
    skip "Store does not support operator" unless capabilities.supports_operator?

    results = ActiveSearch.index(:articles).search("Ruby Programming", operator: "and").results
    assert_equal 1, results.total
    assert_equal @article1.id, results.first.id
  end

  test "quoted phrase requires exact phrase match" do
    skip "Manticore JSON API doesn't support quoted phrase syntax" if store_adapter_name == :manticore

    article_phrase = Article.create!(title: "exact phrase match", content: "Content here", account_id: 1)
    article_words = Article.create!(title: "exact match phrase", content: "Content here", account_id: 1)

    [ article_phrase, article_words ].each { |r| ActiveSearch.index(:articles).add(r) }

    results = ActiveSearch.index(:articles).search("exact phrase").results
    assert_equal 2, results.total

    results = ActiveSearch.index(:articles).search('"exact phrase"').results
    assert_equal 1, results.total
    assert_equal article_phrase.id, results.first.id
  end

  test "mixed phrase and loose terms" do
    skip "Manticore JSON API doesn't support quoted phrase syntax" if store_adapter_name == :manticore

    article1 = Article.create!(title: "Ruby programming language basics", content: "Web development", account_id: 1)
    article2 = Article.create!(title: "Ruby language programming guide", content: "Web development", account_id: 1)

    [ article1, article2 ].each { |r| ActiveSearch.index(:articles).add(r) }

    results = ActiveSearch.index(:articles).search('"programming language"').results
    assert_equal 1, results.total
    assert_equal article1.id, results.first.id
  end

  test "empty query with options" do
    skip "Store does not support operator" unless capabilities.supports_operator?

    results = ActiveSearch.index(:articles).search("", operator: :and).results
    assert_equal 3, results.total
  end

  test "options with pagination" do
    skip "Store does not support operator" unless capabilities.supports_operator?

    results = ActiveSearch.index(:articles).search("Ruby", operator: :or).limit(1).results
    assert_equal 1, results.size
    assert_equal 2, results.total
  end

  test "special characters in query are handled" do
    article = Article.create!(title: "C++ Programming", content: "Learn C++ basics", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Programming").results
    assert_equal 3, results.total
  end
end
