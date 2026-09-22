require "test_helper"

class ResultsTest < ActiveSupport::TestCase
  searches :articles

  def source
    ActiveSearch::Source::Record.new(name: :articles, source_class_name: "Article")
  end

  def build_raw_result(id:, score: 0.0, fields: {}, highlights: {})
    { id: id, score: score, fields: fields, highlights: highlights }
  end

  test "total returns count" do
    results = ActiveSearch::Results.new([], total: 10, definition: nil, source: source)
    assert_equal 10, results.total
  end

  test "iteration loads AR objects via source" do
    article1 = Article.create!(title: "Results Test 1", content: "First", account_id: 1)
    article2 = Article.create!(title: "Results Test 2", content: "Second", account_id: 1)

    raw1 = build_raw_result(id: article1.id.to_s, score: 1.0)
    raw2 = build_raw_result(id: article2.id.to_s, score: 0.5)
    results = ActiveSearch::Results.new([ raw1, raw2 ], total: 2, definition: nil, source: source)

    assert_equal 2, results.size
    assert_includes results.to_a, article1
    assert_includes results.to_a, article2
  end

  test "iteration preserves order from search results" do
    article1 = Article.create!(title: "First", content: "First", account_id: 1)
    article2 = Article.create!(title: "Second", content: "Second", account_id: 1)

    raw1 = build_raw_result(id: article2.id.to_s, score: 1.0)
    raw2 = build_raw_result(id: article1.id.to_s, score: 0.5)
    results = ActiveSearch::Results.new([ raw1, raw2 ], total: 2, definition: nil, source: source)

    assert_equal [ article2, article1 ], results.to_a
  end

  test "result provides score via hit" do
    article = Article.create!(title: "Score Test", content: "Testing score", account_id: 1)

    raw = build_raw_result(id: article.id.to_s, score: 2.5)
    results = ActiveSearch::Results.new([ raw ], total: 1, definition: nil, source: source)

    assert_equal 2.5, results.first.hit.score
  end

  test "empty? returns true when no results" do
    results = ActiveSearch::Results.new([], total: 0, definition: nil, source: source)
    assert results.empty?
  end

  test "empty? returns false when results present" do
    article = Article.create!(title: "Exists", content: "Content", account_id: 1)
    raw = build_raw_result(id: article.id.to_s, score: 1.0)
    results = ActiveSearch::Results.new([ raw ], total: 1, definition: nil, source: source)
    refute results.empty?
  end

  test "any? returns false when no results" do
    results = ActiveSearch::Results.new([], total: 0, definition: nil, source: source)
    refute results.any?
  end

  test "any? returns true when results present" do
    article = Article.create!(title: "Exists", content: "Content", account_id: 1)
    raw = build_raw_result(id: article.id.to_s, score: 1.0)
    results = ActiveSearch::Results.new([ raw ], total: 1, definition: nil, source: source)
    assert results.any?
  end

  test "none? returns true when no results" do
    results = ActiveSearch::Results.new([], total: 0, definition: nil, source: source)
    assert results.none?
  end

  test "none? returns false when results present" do
    article = Article.create!(title: "Exists", content: "Content", account_id: 1)
    raw = build_raw_result(id: article.id.to_s, score: 1.0)
    results = ActiveSearch::Results.new([ raw ], total: 1, definition: nil, source: source)
    refute results.none?
  end

  test "results is enumerable over loaded records" do
    article1 = Article.create!(title: "One", content: "First", account_id: 1)
    article2 = Article.create!(title: "Two", content: "Second", account_id: 1)

    raw1 = build_raw_result(id: article1.id.to_s, score: 1.0)
    raw2 = build_raw_result(id: article2.id.to_s, score: 0.5)
    results = ActiveSearch::Results.new([ raw1, raw2 ], total: 2, definition: nil, source: source)

    titles = results.map(&:title)
    assert_equal [ "One", "Two" ], titles
  end

  test "result provides fields via hit" do
    article = Article.create!(title: "Ruby Programming", content: "Great book", account_id: 1)
    raw = build_raw_result(id: article.id.to_s, score: 1.0, fields: { title: "Ruby Programming", content: "Great book" })
    results = ActiveSearch::Results.new([ raw ], total: 1, definition: nil, source: source)

    result = results.first
    assert_equal "Ruby Programming", result.hit.fields[:title]
    assert_equal({ title: "Ruby Programming", content: "Great book" }, result.hit.fields)
  end

  test "result provides highlights via hit" do
    article = Article.create!(title: "Ruby Programming", content: "Content", account_id: 1)
    raw = build_raw_result(id: article.id.to_s, score: 1.0, highlights: { title: "<mark>Ruby</mark> Programming" })
    results = ActiveSearch::Results.new([ raw ], total: 1, definition: nil, source: source)

    result = results.first
    assert_equal "<mark>Ruby</mark> Programming", result.hit.highlight(:title)
    assert_nil result.hit.highlight(:content)
  end

  test "missing records are silently dropped by default" do
    article = Article.create!(title: "Exists", content: "Content", account_id: 1)

    raw1 = build_raw_result(id: article.id.to_s, score: 1.0)
    raw2 = build_raw_result(id: "999999", score: 0.5)  # Non-existent ID
    results = ActiveSearch::Results.new([ raw1, raw2 ], total: 2, definition: nil, source: source)

    assert_equal 1, results.to_a.size
    assert_equal article, results.first
  end

  test "dropped counts the hits this page could not hand back" do
    article = Article.create!(title: "Exists", content: "Content", account_id: 1)

    raw1 = build_raw_result(id: article.id.to_s, score: 1.0)
    raw2 = build_raw_result(id: "999999", score: 0.5)
    results = ActiveSearch::Results.new([ raw1, raw2 ], total: 2, definition: nil, source: source)

    assert_equal 1, results.dropped
    assert_equal 2, results.total, "total still counts index hits"
  end

  test "the extra hit fetched for next_page? is not counted as dropped" do
    kept = Article.create!(title: "Extra", content: "c", account_id: 1)
    present = build_raw_result(id: kept.id.to_s, score: 1.0)
    probe = build_raw_result(id: "999999", score: 0.5)

    results = ActiveSearch::Results.new([ present, probe ], total: 2, definition: nil,
      source: source, limit: 1, fetched_extra_hit: true)

    assert_equal 0, results.dropped, "the probe row was never part of the page"
    assert_predicate results, :next_page?
  end

  test "a missing hit inside the page is counted even when an extra was fetched" do
    gone = build_raw_result(id: "999998", score: 1.0)
    probe = build_raw_result(id: "999999", score: 0.5)

    results = ActiveSearch::Results.new([ gone, probe ], total: 2, definition: nil,
      source: source, limit: 1, fetched_extra_hit: true)

    assert_equal 1, results.dropped
    assert_predicate results, :next_page?
  end

  test "dropped is zero when every hit hydrated" do
    article = Article.create!(title: "Exists", content: "Content", account_id: 1)
    raw = build_raw_result(id: article.id.to_s, score: 1.0)

    assert_equal 0, ActiveSearch::Results.new([ raw ], total: 1, definition: nil, source: source).dropped
  end

  test "result.hit.field with non-existent field returns nil" do
    article = Article.create!(title: "Test", content: "Content", account_id: 1)
    raw = build_raw_result(id: article.id.to_s, score: 1.0, fields: { title: "Test" })
    results = ActiveSearch::Results.new([ raw ], total: 1, definition: nil, source: source)

    result = results.first
    assert_nil result.hit.fields[:nonexistent]
  end

  test "result.hit.highlight with non-highlighted field returns nil" do
    article = Article.create!(title: "Test", content: "Content", account_id: 1)
    raw = build_raw_result(id: article.id.to_s, score: 1.0, highlights: { title: "<mark>Test</mark>" })
    results = ActiveSearch::Results.new([ raw ], total: 1, definition: nil, source: source)

    result = results.first
    assert_nil result.hit.highlight(:nonexistent)
  end

  test "results with deleted source records excludes them" do
    article1 = Article.create!(title: "Keep This", content: "First", account_id: 1)
    article2 = Article.create!(title: "Delete This", content: "Second", account_id: 1)
    deleted_id = article2.id
    article2.delete

    raw1 = build_raw_result(id: article1.id.to_s, score: 1.0)
    raw2 = build_raw_result(id: deleted_id.to_s, score: 0.5)
    results = ActiveSearch::Results.new([ raw1, raw2 ], total: 2, definition: nil, source: source)

    assert_equal 1, results.to_a.size
    assert_equal article1.id, results.first.id
  end

  test "results size returns count of results in page" do
    article1 = Article.create!(title: "One", content: "First", account_id: 1)
    article2 = Article.create!(title: "Two", content: "Second", account_id: 1)
    raw1 = build_raw_result(id: article1.id.to_s, score: 1.0)
    raw2 = build_raw_result(id: article2.id.to_s, score: 0.5)
    results = ActiveSearch::Results.new([ raw1, raw2 ], total: 100, definition: nil, source: source)

    assert_equal 2, results.size
    assert_equal results.to_a.size, results.size
    assert_equal 100, results.total
  end

  test "each with a block returns the results, not the internal array" do
    article = Article.create!(title: "Each", content: "Content", account_id: 1)
    raw = build_raw_result(id: article.id.to_s, score: 1.0)
    results = ActiveSearch::Results.new([ raw ], total: 1, definition: nil, source: source)

    assert_same results, results.each { |_record| }
  end

  test "mutating what each hands back does not shrink the page" do
    article = Article.create!(title: "Each Mutation", content: "Content", account_id: 1)
    raw = build_raw_result(id: article.id.to_s, score: 1.0)
    results = ActiveSearch::Results.new([ raw ], total: 1, definition: nil, source: source)

    results.each { |_record| }.to_a.clear

    assert_equal 1, results.size
    assert_equal [ article ], results.to_a
  end

  test "each without a block returns an enumerator over the records" do
    article = Article.create!(title: "Each Enum", content: "Content", account_id: 1)
    raw = build_raw_result(id: article.id.to_s, score: 1.0)
    results = ActiveSearch::Results.new([ raw ], total: 1, definition: nil, source: source)

    assert_kind_of Enumerator, results.each
    assert_equal [ article ], results.each.to_a
    assert_same results, results.each.each { |_record| }
  end

  test "mutating through the enumerator from each does not shrink the page" do
    article = Article.create!(title: "Each Enum Mutation", content: "Content", account_id: 1)
    raw = build_raw_result(id: article.id.to_s, score: 1.0)
    results = ActiveSearch::Results.new([ raw ], total: 1, definition: nil, source: source)

    results.each.each { |_record| }.to_a.clear

    assert_equal 1, results.size
  end

  test "size matches to_a.size when a hit does not hydrate" do
    article = Article.create!(title: "Survivor", content: "Still here", account_id: 1)
    src = source

    raw1 = build_raw_result(id: article.id.to_s, score: 1.0)
    raw2 = build_raw_result(id: "999999", score: 0.5)
    results = ActiveSearch::Results.new([ raw1, raw2 ], total: 2, definition: nil, source: src)

    assert_equal 1, results.size
    assert_equal results.to_a.size, results.size
  end
end
