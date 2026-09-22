require "test_helper"

class HitFieldsTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  searches :articles

  def index
    ActiveSearch.index(:articles)
  end

  test "a hit reads a field by name, and takes a String as highlight does" do
    index.add(Article.create!(title: "Readable Test", content: "Content", account_id: 1))

    hit = index.search("Readable").results.first&.hit
    assert hit, "premise: the search must find something"

    assert_equal hit.fields[:title], hit.field(:title)
    assert_equal hit.fields[:title], hit.field("title")
  end

  test "hit_fields can be chained with search" do
    article = Article.create!(title: "Chainable Test", content: "Content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = index.hit_fields(:title).search("Chainable").results
    assert_equal 1, results.total
    assert_equal "Chainable Test", results.first.hit.fields[:title]
  end

  test "select raises QueryError for unknown fields" do
    assert_raises(ActiveSearch::QueryError) do
      index.hit_fields(:unknown_field)
    end
  end

  test "hit fields returns selected values" do
    article = Article.create!(title: "Select Test", content: "Test content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Select").hit_fields(:title, :content).results
    result = results.first

    assert_equal({ title: "Select Test", content: "Test content" }.slice(:title, :content), result.hit.fields.slice(:title, :content))
  end

  test "hit field returns individual value" do
    article = Article.create!(title: "Field Test", content: "Test content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Field").hit_fields(:title).results
    result = results.first

    assert_equal "Field Test", result.hit.fields[:title]
  end

  test "hit fields returns all fields when no hit_fields clause" do
    article = Article.create!(title: "All Fields Test", content: "Test content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("All Fields").results
    result = results.first

    assert result.hit.fields.key?(:title)
    assert result.hit.fields.key?(:content)
  end

  test "select can be chained with other methods" do
    Article.create!(title: "Chain Test", content: "Content", account_id: 1).tap { |a| ActiveSearch.index(:articles).add(a) }
    Article.create!(title: "Chain Test", content: "Content", account_id: 2).tap { |a| ActiveSearch.index(:articles).add(a) }

    results = ActiveSearch.index(:articles).search("Chain")
      .hit_fields(:title)
      .filter(account_id: 1)
      .results

    assert_equal 1, results.total
    result = results.first
    assert result.hit.fields.key?(:title)
  end

  test "a page cut by limit and offset carries the selected hit fields" do
    3.times { |i| Article.create!(title: "Paginated #{i}", content: "Content", account_id: 1).tap { |a| ActiveSearch.index(:articles).add(a) } }

    results = ActiveSearch.index(:articles).search("Paginated")
      .hit_fields(:title)
      .limit(2)
      .offset(1)
      .results

    assert_equal 2, results.size
    results.each do |result|
      assert result.hit.fields.key?(:title)
    end
  end

  test "AR record attributes are separate from hit fields" do
    article = Article.create!(title: "Separate Test", content: "Test content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Separate").hit_fields(:title).results
    result = results.first

    assert_equal "Separate Test", result.title

    assert_equal "Separate Test", result.hit.fields[:title]

    assert_equal result.title, result.hit.fields[:title]
  end
end
