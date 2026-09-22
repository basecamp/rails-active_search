require "test_helper"

class HitLifetimeTest < ActiveSupport::TestCase
  searches :articles

  setup do
    @article = Article.create!(title: "Hit Lifetime", content: "Metadata", account_id: 1, status: "published")
    ActiveSearch.index(:articles).add(@article)
  end

  def found
    Article.search("Metadata").results.first
  end

  test "an independently loaded record has no hit" do
    assert_nil Article.find(@article.id).hit
    assert_nil Article.new.hit
    assert_nil @article.hit, "the instance that was indexed did not come from a search either"
  end

  test "a hydrated record has one" do
    assert_kind_of ActiveSearch::Hit, found.hit
  end

  test "the hit is frozen, and so are its collections" do
    hit = found.hit

    assert_predicate hit, :frozen?
    assert_predicate hit.fields, :frozen?
    assert_predicate hit.highlights, :frozen?
  end

  test "the hit has no writers" do
    hit = found.hit

    %i[score= fields= highlights=].each do |writer|
      assert_not hit.respond_to?(writer), "#{writer} would let a caller edit a record of what the backend returned"
    end
  end

  test "mutating the hit raises rather than succeeding quietly" do
    hit = found.hit

    assert_raises(FrozenError) { hit.fields[:injected] = "x" }
    assert_raises(FrozenError) { hit.highlights[:title] = "x" }
  end

  test "the hit holds a copy rather than the adapter's own collections" do
    fields = { author_name: "Ada" }
    highlights = { title: "<mark>Hit</mark>" }
    hit = ActiveSearch::Hit.new(score: 1.0, fields: fields, highlights: highlights)

    assert_not_same fields, hit.fields
    assert_not_same highlights, hit.highlights
    assert_not fields.frozen?, "freezing the caller's hash would be a side effect on their object"
  end

  test "the metadata stays on the instance for its lifetime" do
    record = found
    hit = record.hit

    record.reload
    assert_same hit, record.hit, "reload must not clear search metadata"

    record.update!(status: "archived")
    assert_same hit, record.hit, "an unrelated write must not clear it"
  end

  test "a later search replaces it on the same object" do
    record = found
    first = record.hit

    replacement = ActiveSearch::Hit.new(score: 99.0)
    record.hit = replacement

    assert_same replacement, record.hit
    assert_not_same first, record.hit
  end

  test "two hydrations produce separate hits" do
    first = found
    second = found

    assert_equal first.id, second.id
    assert_not_same first.hit, second.hit,
      "each hydration attaches its own copy rather than sharing one"
  end

  test "score, fields and highlight are what a Hit answers" do
    hit = found.hit

    assert_kind_of Float, hit.score
    assert_kind_of Hash, hit.fields
    assert_nil hit.highlight(:nonexistent)
  end

  test "highlight accepts a String or a Symbol" do
    hit = ActiveSearch::Hit.new(highlights: { title: "<mark>x</mark>" })

    assert_equal "<mark>x</mark>", hit.highlight(:title)
    assert_equal "<mark>x</mark>", hit.highlight("title")
  end
end
