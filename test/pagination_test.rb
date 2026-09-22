require "test_helper"

class PaginationTest < ActiveSupport::TestCase
  searches :articles

  setup do
    @original_limit = Rails.application.config.active_search.default_limit
    idx = ActiveSearch.index(:articles)
    30.times do |i|
      idx.add(Article.create!(title: "Ruby guide #{i}", content: "ruby #{i}", account_id: 1,
        published_at: Time.utc(2026, 1, 1) + i.days))
    end
    idx.store.refresh(:articles) rescue nil
  end

  teardown do
    Rails.application.config.active_search.default_limit = @original_limit
  end

  def limit_in(query)
    if query.respond_to?(:limit_value)
      query.limit_value
    elsif query[:args]
      index = query[:args].index("LIMIT")
      index && query[:args][index + 2]
    else
      query[:size] || query[:rows] || query[:limit] || query.dig(:params, :limit)
    end
  end

  def fetched_limit(limit)
    ActiveSearch.index(:articles).store.capabilities.approximate_totals? ? limit + 1 : limit
  end

  test "ships with a default limit applied to every adapter" do
    assert_equal 25, @original_limit
    results = ActiveSearch.index(:articles).search("ruby").results

    assert_equal 25, results.size
    assert_equal 30, results.total
    assert_predicate results, :next_page?
  end

  test "applies the default limit when the relation sets none" do
    Rails.application.config.active_search.default_limit = 5
    results = ActiveSearch.index(:articles).search("ruby").results

    assert_equal 5, results.size
    assert_equal 30, results.total
  end

  test "an explicit limit wins over the default" do
    Rails.application.config.active_search.default_limit = 5
    results = ActiveSearch.index(:articles).search("ruby").limit(12).results

    assert_equal 12, results.size
  end

  test "the default reaches to_native_query, not just results" do
    Rails.application.config.active_search.default_limit = 5
    query = ActiveSearch.index(:articles).search("ruby").to_native_query

    assert_equal 5, limit_in(query)
  end

  test "a nil default sends no limit, leaving each store its own" do
    Rails.application.config.active_search.default_limit = nil
    query = ActiveSearch.index(:articles).search("ruby").to_native_query

    assert_nil limit_in(query)
  end

  test "the limit-plus-one hit stays inside the executed request" do
    query = ActiveSearch.index(:articles).search("ruby").limit(5)
    store = ActiveSearch.index(:articles).store

    assert_equal 5, limit_in(query.to_native_query)
    assert_equal fetched_limit(5), store.context_with_extra_hit(query_context_for(query)).limit
  end

  test "the extra hit never reaches the page" do
    results = ActiveSearch.index(:articles).search("ruby").limit(5).results

    assert_equal 5, results.size
    assert_predicate results, :next_page?
  end

  test "next_page? reports when the store held matches back" do
    Rails.application.config.active_search.default_limit = 5

    assert_predicate ActiveSearch.index(:articles).search("ruby").results, :next_page?
    assert_not_predicate ActiveSearch.index(:articles).search("ruby").limit(30).results, :next_page?
  end

  test "next_page? follows the offset through to the last page" do
    query = ActiveSearch.index(:articles).search("ruby").sort(published_at: :asc).limit(10)

    assert_predicate query.results, :next_page?
    assert_predicate query.offset(10).results, :next_page?
    assert_not_predicate query.offset(20).results, :next_page?
  end

  test "an offset past the end returns an empty page with no next page" do
    results = ActiveSearch.index(:articles).search("ruby").limit(10).offset(30).results

    assert_empty results
    assert_equal 30, results.total
    assert_not_predicate results, :next_page?
  end

  def results_for(rows, total:, **options)
    index = ActiveSearch.index(:articles)
    ActiveSearch::Results.new(rows, total: total, definition: index.definition, source: index.source, **options)
  end

  def rows_for(records)
    records.map { |record| { id: record.id.to_s, score: 1.0, fields: {}, highlights: {} } }
  end

  test "an exact total answers next_page? by arithmetic rather than from a fetched extra" do
    articles = Article.order(:id).limit(5)

    assert_predicate results_for(rows_for(articles), total: 30, limit: 5), :next_page?
    assert_not_predicate results_for(rows_for(articles), total: 5, limit: 5), :next_page?
    assert_not_predicate results_for(rows_for(articles), total: 25, limit: 5, offset: 20), :next_page?
  end

  test "an estimated total answers next_page? from the extra hit rather than by arithmetic" do
    rows = rows_for(Article.order(:id).limit(6))
    results = results_for(rows, total: 3, total_relation: :estimate, limit: 5, fetched_extra_hit: true)

    assert_equal 5, results.size
    assert_predicate results, :next_page?
    assert_not_predicate results, :total_exact?
    assert_not_predicate results_for(rows.first(5), total: 3, total_relation: :estimate, limit: 5, fetched_extra_hit: true),
      :next_page?
  end

  test "a lower-bound total answers next_page? from the extra hit too" do
    rows = rows_for(Article.order(:id).limit(6))

    assert_predicate results_for(rows, total: 5, total_relation: :lower_bound, limit: 5, fetched_extra_hit: true),
      :next_page?
    assert_not_predicate results_for(rows.first(5), total: 5, total_relation: :lower_bound, limit: 5, fetched_extra_hit: true),
      :next_page?
  end

  test "an inexact total with no limit falls back to arithmetic" do
    rows = rows_for(Article.order(:id).limit(5))

    assert_predicate results_for(rows, total: 30, total_relation: :estimate), :next_page?
    assert_not_predicate results_for(rows, total: 5, total_relation: :estimate), :next_page?
  end

  test "a total relation outside the three raises" do
    error = assert_raises(ArgumentError) do
      results_for([], total: 0, total_relation: :approximately)
    end

    assert_match(/equal, lower_bound, estimate/, error.message)
  end

  test "rows beyond the limit survive when no extra hit was fetched" do
    rows = rows_for(Article.order(:id).limit(6))
    results = results_for(rows, total: 30, limit: 5)

    assert_equal 6, results.size
  end

  test "a total the source cannot hydrate shortens the page without changing next_page?" do
    articles = Article.order(:id).limit(5).to_a
    rows = rows_for(articles)
    rows[2] = { id: "0", score: 1.0, fields: {}, highlights: {} }
    results = results_for(rows, total: 30, limit: 5)

    assert_equal 4, results.size
    assert_equal 30, results.total
    assert_predicate results, :next_page?
  end

  test "a zero limit reports the total without returning a row" do
    results = ActiveSearch.index(:articles).search("ruby").limit(0).results

    assert_empty results
    assert_equal 30, results.total
    assert_predicate results, :next_page?
  end

  test "count keeps its Enumerable meanings" do
    results = ActiveSearch.index(:articles).search("ruby").limit(5).results

    assert_equal 5, results.count
    assert_equal 5, results.length
    assert_equal 5, results.size
    assert_equal 0, results.count { |article| article.status == "archived" }
    assert_equal 5, results.count { |article| article.status == "published" }
  end

  test "a page past the store's result window is refused before the store sees it" do
    skip "store pages without a declared window" unless window

    error = assert_raises(ActiveSearch::ResultWindowExceeded) do
      ActiveSearch.index(:articles).search("ruby").limit(50).offset(window).results
    end

    assert_match(/pages to #{window} results/, error.message)
  end

  test "the last page inside the window is served" do
    skip "store pages without a declared window" unless window

    assert_nothing_raised do
      ActiveSearch.index(:articles).search("ruby").limit(50).offset(window - 50).results
    end
  end

  test "an unlimited query is still refused past the window" do
    skip "store pages without a declared window" unless window

    assert_raises(ActiveSearch::ResultWindowExceeded) do
      ActiveSearch.index(:articles).search("ruby").limit(nil).offset(window).results
    end
  end

  CAPPED_BY_GEM = %i[ sqlite postgresql mysql manticore ].freeze

  test "a server-side adapter with no engine cap declares its own result window" do
    skip "#{store_adapter_name} is capped by its engine or already declares a window" unless
      CAPPED_BY_GEM.include?(store_adapter_name)

    assert_not_nil window,
      "#{store_adapter_name} materializes an unbounded page instead of refusing it"

    assert_raises(ActiveSearch::ResultWindowExceeded) do
      ActiveSearch.index(:articles).search("ruby").limit(50).offset(window).results
    end
  end

  test "a page past the store's result window is refused when it is built" do
    skip "store pages without a declared window" unless window

    error = assert_raises(ActiveSearch::ResultWindowExceeded) do
      ActiveSearch.index(:articles).search("ruby").page(window / 50 + 1, per_page: 50)
    end

    assert_match(/pages to #{window} results/, error.message)
  end

  test "the last page ending on the window is built" do
    skip "store pages without a declared window" unless window

    page = ActiveSearch.index(:articles).search("ruby").page(window / 50, per_page: 50)

    assert_equal window, page.offset + page.limit
  end

  class CappedStore < ActiveSearch::StoreAdapters::Base
    def capabilities
      ActiveSearch::Capabilities.new(max_result_window: 1_000)
    end
  end

  class UncappedStore < ActiveSearch::StoreAdapters::Base
    def capabilities
      ActiveSearch::Capabilities.new
    end
  end

  StubIndex = Struct.new(:store)

  test "a page a capped store refuses is built on a store declaring no window" do
    assert_raises(ActiveSearch::ResultWindowExceeded) { deep_page_on(CappedStore.new) }

    assert_equal 11_970, deep_page_on(UncappedStore.new).offset
  end

  private
    def window
      ActiveSearch.index(:articles).capabilities.max_result_window
    end

    def deep_page_on(store)
      ActiveSearch::Query.new(index: StubIndex.new(store)).page(400, per_page: 30)
    end
end
