require "test_helper"

class PageTest < ActiveSupport::TestCase
  searches :articles

  GEARS = [ 10, 30, 50 ].freeze

  GEARED_WINDOWS = [
    [ 1, 10, 0 ],
    [ 2, 30, 10 ],
    [ 3, 50, 40 ],
    [ 4, 50, 90 ],
    [ 5, 50, 140 ]
  ].freeze

  test "sizes grow through the list and then hold" do
    GEARED_WINDOWS.each do |number, limit, offset|
      page = ActiveSearch.index(:articles).all.page(number, per_page: GEARS)

      assert_equal limit, page.limit, "page #{number} limit"
      assert_equal offset, page.offset, "page #{number} offset"
    end
  end

  test "an offset is where the previous page ended" do
    GEARED_WINDOWS.each_cons(2) do |(_, limit, offset), (number, _, next_offset)|
      assert_equal offset + limit, next_offset, "page #{number} must start where page #{number - 1} ended"
    end
  end

  test "one size is the same rule with a list of one" do
    [ [ 1, 0 ], [ 2, 20 ], [ 3, 40 ] ].each do |number, offset|
      page = ActiveSearch.index(:articles).all.page(number, per_page: 20)

      assert_equal 20, page.limit
      assert_equal offset, page.offset, "page #{number}"
    end
  end

  test "no size given takes the configured default" do
    page = ActiveSearch.index(:articles).all.page(2)

    assert_equal [ 25 ], page.per_page
    assert_equal 25, page.offset
  end

  WINDOWED = {
    "limit" => -> { ActiveSearch.index(:articles).all.limit(20) },
    "unlimited" => -> { ActiveSearch.index(:articles).all.limit(nil) },
    "zero limit" => -> { ActiveSearch.index(:articles).all.limit(0) },
    "offset" => -> { ActiveSearch.index(:articles).all.offset(100) },
    "both" => -> { ActiveSearch.index(:articles).all.limit(20).offset(100) }
  }.freeze

  test "a page is refused on a query that already sets a window" do
    WINDOWED.each do |name, build|
      error = assert_raises(ActiveSearch::QueryError, name) { build.call.page(2) }

      assert_match(/per_page/, error.message, name)
    end
  end

  test "a window set after the page cannot exist, because a page is not a query" do
    page = ActiveSearch.index(:articles).all.page(2, per_page: 10)

    %i[ filter reject sort search highlight native results= ].each do |method|
      assert_not_respond_to page, method
    end

    assert_raises(ArgumentError) { page.limit(5) }
    assert_raises(ArgumentError) { page.offset(5) }
  end

  test "a page holds the rows its window describes" do
    articles = (1..12).map { |n| index_article("Geared #{n}") }

    first = ActiveSearch.index(:articles).search("Geared").sort(account_id: :asc).page(1, per_page: [ 4, 8 ])
    second = ActiveSearch.index(:articles).search("Geared").sort(account_id: :asc).page(2, per_page: [ 4, 8 ])

    assert_equal articles.first(4).map(&:id), first.results.map(&:id)
    assert_equal articles.drop(4).map(&:id), second.results.map(&:id)
  end

  test "the number is the one that was asked for" do
    assert_equal 3, ActiveSearch.index(:articles).all.page(3, per_page: GEARS).number
  end

  test "the results carry the numbers a page does not" do
    3.times { |n| index_article("Carried #{n}") }

    page = ActiveSearch.index(:articles).search("Carried").page(1, per_page: 2)

    assert_equal 3, page.results.total
    assert_equal 0, page.results.dropped
    assert_respond_to page.results, :total_exact?
  end

  test "the first page has no previous and the last has no next" do
    3.times { |n| index_article("Edges #{n}") }

    first = ActiveSearch.index(:articles).search("Edges").page(1, per_page: 2)
    last = ActiveSearch.index(:articles).search("Edges").page(2, per_page: 2)

    assert_not first.previous?
    assert first.next?
    assert last.previous?
    assert_not last.next?
  end

  test "a page count walks the sizes rather than dividing by one" do
    12.times { |n| index_article("Walked #{n}") }

    assert_equal 2, ActiveSearch.index(:articles).search("Walked").page(1, per_page: [ 4, 8 ]).page_count

    index_article("Walked 13")

    assert_equal 3, ActiveSearch.index(:articles).search("Walked").page(1, per_page: [ 4, 8 ]).page_count
  end

  test "a page count past the list divides the tail rather than walking it" do
    page = ActiveSearch.index(:articles).all.page(1, per_page: GEARS)
    page.define_singleton_method(:results) { Struct.new(:total).new(10_000_000_090) }

    assert_equal 200_000_003, page.page_count
  end

  test "an empty result set is no pages" do
    page = ActiveSearch.index(:articles).search("Absent").page(1, per_page: 5)

    assert_equal 0, page.results.total
    assert_equal 0, page.page_count
    assert page.results.empty?
    assert_not page.next?
    assert_not page.previous?
  end

  PAGE_NUMBERS = { "3" => 3, 3 => 3, 2.9 => 2, 0 => 1, -1 => 1, "abc" => 1, nil => 1, "" => 1 }.freeze

  test "a page number is coerced, because it arrives from a URL" do
    PAGE_NUMBERS.each do |given, expected|
      page = ActiveSearch.index(:articles).all.page(given, per_page: 10)

      assert_equal expected, page.number, "page(#{given.inspect})"
    end
  end

  test "a page size truncates a fraction, as limit does" do
    require "bigdecimal"

    { 20 => 20, "20" => 20, 20.7 => 20,
      BigDecimal("20.0000000000000000000000000000000000001") => 20 }.each do |given, expected|
      page = ActiveSearch.index(:articles).all.page(1, per_page: given)

      assert_equal [ expected ], page.per_page, "per_page: #{given.inspect}"
    end
  end

  test "a page size that is not a number, or not positive, is refused" do
    [ 0, -5, [], [ 10, 0 ], "x", false, [ 10, "x" ] ].each do |size|
      assert_raises(ActiveSearch::QueryError, "per_page: #{size.inspect}") do
        ActiveSearch.index(:articles).all.page(1, per_page: size)
      end
    end
  end

  test "no size and no default is refused rather than guessed at" do
    original = Rails.application.config.active_search.default_limit
    Rails.application.config.active_search.default_limit = nil

    assert_raises(ActiveSearch::QueryError) { ActiveSearch.index(:articles).all.page(1) }
  ensure
    Rails.application.config.active_search.default_limit = original
  end

  test "a page does not answer the chaining methods that would move its window" do
    page = ActiveSearch.index(:articles).all.page(2, per_page: 10)

    %i[ filter reject sort search highlight native ].each do |method|
      assert_not_respond_to page, method
    end

    assert_raises(ArgumentError) { page.limit(5) }
    assert_equal 10, page.limit
    assert_equal 10, page.offset
  end

  test "a page holds a position, and the rows live on its results" do
    page = ActiveSearch.index(:articles).all.page(1, per_page: 5)

    assert_not_respond_to page, :each
    assert_not_respond_to page, :count
    assert_kind_of ActiveSearch::Results, page.results
  end

  private
    def index_article(title)
      article = Article.create!(title: title, content: "body", account_id: @seq = (@seq || 0) + 1)
      ActiveSearch.index(:articles).add(article)
      refresh_articles
      article
    end

    def refresh_articles
      ActiveSearch.index(:articles).store.refresh(:articles)
    rescue StandardError
      nil
    end
end
