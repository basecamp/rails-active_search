require "test_helper"

class DocumentationExamplesTest < ActiveSupport::TestCase
  searches :articles

  setup do
    @article = Article.create!(
      title: "Rails Search", content: "Full text search in Rails",
      account_id: 1, status: "published", featured: true,
      published_at: Time.utc(2024, 6, 1)
    )
    @other = Article.create!(
      title: "Python Guide", content: "Full text search in Python",
      account_id: 2, status: "draft", featured: false,
      published_at: Time.utc(2023, 1, 1)
    )

    [ @article, @other ].each { |r| ActiveSearch.index(:articles).add(r) }
  end

  test "the Quick Start search example runs and yields hit metadata" do
    results = Article.search("Rails").results

    assert_equal 1, results.size
    article = results.first

    assert_equal "Rails Search", article.title
    assert_kind_of Float, article.hit.score
  end

  test "a Query is not Enumerable and Results is" do
    query = Article.search("search")

    assert_not query.respond_to?(:each), "the README says Query is not Enumerable"
    assert_respond_to query.results, :each
  end

  test "chained methods return a new query in any order" do
    base = Article.search("search")
    filtered = base.filter(status: "published")

    assert_not_same base, filtered
    assert_results [ @article, @other ], base, "the original query is unchanged"
    assert_results @article, filtered
  end

  test "the filtering examples run" do
    assert_results @article, Article.search("search").filter(status: "published")
    assert_results [ @article, @other ], Article.search("search").filter(status: [ "published", "draft" ])
    assert_results @article, Article.search("search").filter(account_id: ..1)
    assert_results @article, Article.search("search").filter(featured: true)
  end

  test "the reject example excludes matching documents" do
    assert_results @other, Article.search("search").reject(status: "published")
  end

  test "reject combined with filter" do
    assert_results @article,
      Article.search("search").filter(account_id: 1).reject(status: "draft")
  end

  test "fields: selects which text fields are searched" do
    assert_results @article, Article.search("Rails", fields: [ :title ])
  end

  test "a filter-only query needs no text" do
    assert_results @article, Article.search.filter(status: "published")
  end

  test "sort and sort_by_relevance run" do
    assert_nothing_raised { Article.search("search").sort(published_at: :desc).results }
    assert_nothing_raised { Article.search("search").sort_by_relevance.results }
  end

  test "the operator example runs where the adapter supports it" do
    if capabilities.supports_operator?
      assert_nothing_raised { Article.search("rails search", operator: :and).results }
    else
      assert_raises(ActiveSearch::UnsupportedOperationError) do
        Article.search("rails search", operator: :and)
      end
    end
  end

  test "to_native_query returns the documented shape for this adapter" do
    native = ActiveSearch.index(:articles).search("ruby").to_native_query

    if %i[sqlite mysql postgresql].include?(store_adapter_name)
      assert_kind_of ActiveRecord::Relation, native,
        "the README says database adapters return an ActiveRecord relation"
    else
      assert_not_kind_of ActiveRecord::Relation, native
    end
  end

  test "the native example customises the request before execution" do
    skip "the README example is Elasticsearch-shaped" unless
      %i[elasticsearch opensearch].include?(store_adapter_name)

    query = ActiveSearch.index(:articles).search("search").native do |request|
      request[:timeout] = "5s"
      request
    end

    assert_equal "5s", query.to_native_query[:timeout]
    assert_nothing_raised { query.results }
  end

  test "the mergeable relation example composes with another model's query" do
    skip "to_native_query is not a relation on #{store_adapter_name}" unless
      %i[sqlite mysql postgresql].include?(store_adapter_name)

    scope = ActiveSearch.index(:articles).search("search").limit(nil).to_native_query

    assert_kind_of ActiveRecord::Relation, scope
    assert_nil scope.limit_value, "the README says limit(nil) opts out of the default"
  end

  test "the highlight(true) example runs and marks the term" do
    skip "adapter has no highlighting" unless supports_highlighting?

    results = Article.search("Rails").highlight(true).results

    assert_match(/Rails/, results.first.hit.highlight(:title).to_s)
  end

  test "the per-field example needs per-field markers and per-field snippets together" do
    skip "adapter has no highlighting" unless supports_highlighting?
    unit = ActiveSearch::Highlighting::FieldOptions::UNITS.find { |u| capabilities.supports_snippet_unit?(u) }
    skip "adapter has no snippet units" unless unit

    example = -> do
      Article.search("Rails").highlight(
        title: { markers: [ "<em>", "</em>" ] },
        content: { snippet: { unit => 15 } }
      ).results
    end

    if supports_highlight_per_field_markers? && supports_highlight_per_field_snippets?
      assert_nothing_raised { example.call }
    else
      assert_raises(ActiveSearch::UnsupportedOperationError) { example.call }
    end
  end

  test "differing options across fields are gated by the per-field capabilities" do
    skip "adapter has no highlighting" unless supports_highlighting?
    unit = ActiveSearch::Highlighting::FieldOptions::UNITS.find { |u| capabilities.supports_snippet_unit?(u) }
    skip "adapter has no snippet units" unless unit

    differing_markers = -> do
      Article.search("Rails").highlight(
        title: { markers: [ "<em>", "</em>" ] },
        content: { markers: [ "<b>", "</b>" ] }
      ).results
    end

    differing_snippets = -> do
      Article.search("Rails").highlight(
        title: { snippet: { unit => 5 } },
        content: { snippet: { unit => 15 } }
      ).results
    end

    if supports_highlight_per_field_markers?
      assert_nothing_raised { differing_markers.call }
    else
      assert_raises(ActiveSearch::UnsupportedOperationError) { differing_markers.call }
    end

    if supports_highlight_per_field_snippets?
      assert_nothing_raised { differing_snippets.call }
    else
      assert_raises(ActiveSearch::UnsupportedOperationError) { differing_snippets.call }
    end
  end

  test "the Results interface is as documented" do
    results = Article.search("search").results

    assert_equal 2, results.size
    assert_equal 2, results.total
    assert_not results.empty?
    assert_not results.next_page?
    assert_not results.partial?
    assert_includes [ true, false ], results.total_exact?
    assert_respond_to results, :each
  end

  test "the README's capability line on exact totals matches the store" do
    always_exact = !ActiveSearch.index(:articles).store.capabilities.approximate_totals?

    if %i[elasticsearch opensearch meilisearch manticore].include?(store_adapter_name)
      assert_not always_exact, "#{store_adapter_name} can report an inexact total, as the README says"
    else
      assert always_exact, "#{store_adapter_name} always counts exactly, as the README says"
    end
  end

  test "whether a total is exact is a property of the page, not of the store" do
    results = Article.search("search").results

    assert_equal 2, results.total

    if store_adapter_name == :meilisearch
      assert_not_predicate results, :total_exact?
    else
      assert_predicate results, :total_exact?
    end
  end

  test "the documented default limit is what ships" do
    assert_equal 25, Rails.application.config.active_search.default_limit
  end

  test "every capability the README lists is answerable through the index" do
    caps = ActiveSearch.index(:articles).capabilities

    %i[
      supports_highlighting? supports_operator? supports_missing_filters?
      supports_search_subfields? supports_search_string_fields? supports_collection_ranges?
    ].each { |predicate| assert_includes [ true, false ], caps.public_send(predicate) }

    ActiveSearch::Highlighting::FieldOptions::UNITS.each { |u| assert_includes [ true, false ], caps.supports_snippet_unit?(u) }
  end

  CAPABILITY_MATRIX = {
    elasticsearch: { highlighting: true, units: [ :characters ], markers: true, snippets: true, operator: true, missing: true, subfields: true, string_fields: true, ranges: true },
    opensearch: { highlighting: true, units: [ :characters ], markers: true, snippets: true, operator: true, missing: true, subfields: true, string_fields: true, ranges: true },
    solr: { highlighting: true, units: [ :characters ], markers: true, snippets: true, operator: true, missing: true, subfields: false, string_fields: false, ranges: true },
    meilisearch: { highlighting: true, units: [ :words ], markers: true, snippets: true, operator: false, missing: true, subfields: false, string_fields: false, ranges: false },
    typesense: { highlighting: true, units: [ :words ], markers: true, snippets: false, operator: true, missing: false, subfields: false, string_fields: false, ranges: false },
    postgresql: { highlighting: true, units: [ :words ], markers: true, snippets: true, operator: false, missing: true, subfields: false, string_fields: false, ranges: true },
    sqlite: { highlighting: true, units: [ :words ], markers: true, snippets: true, operator: false, missing: true, subfields: false, string_fields: false, ranges: true },
    mysql: { highlighting: false, units: [], markers: false, snippets: false, operator: false, missing: true, subfields: false, string_fields: false, ranges: false },
    redis_search: { highlighting: true, units: [], markers: false, snippets: false, operator: false, missing: true, subfields: false, string_fields: false, ranges: false },
    manticore: { highlighting: true, units: [ :characters ], markers: false, snippets: false, operator: false, missing: false, subfields: false, string_fields: false, ranges: true }
  }.freeze

  test "this adapter's row in the README capability matrix is accurate" do
    row = CAPABILITY_MATRIX.fetch(store_adapter_name)
    caps = ActiveSearch.index(:articles).capabilities

    assert_equal row[:highlighting], caps.supports_highlighting?, "highlight column"
    ActiveSearch::Highlighting::FieldOptions::UNITS.each do |unit|
      assert_equal row[:units].include?(unit), caps.supports_snippet_unit?(unit), "snippet units column (#{unit})"
    end
    assert_equal row[:markers], caps.supports_highlight_per_field_markers?, "per-field markers column"
    assert_equal row[:snippets], caps.supports_highlight_per_field_snippets?, "per-field snippets column"
    assert_equal row[:operator], caps.supports_operator?, "operator column"
    assert_equal row[:missing], caps.supports_missing_filters?, "missing filters column"
    assert_equal row[:subfields], caps.supports_search_subfields?, "subfields column"
    assert_equal row[:string_fields], caps.supports_search_string_fields?, "string-field search column"
    assert_equal row[:ranges], caps.supports_collection_ranges?, "collection ranges column"
  end

  README_ADAPTER_NAMES = {
    "Elasticsearch" => :elasticsearch, "OpenSearch" => :opensearch, "Solr" => :solr,
    "Meilisearch" => :meilisearch, "Typesense" => :typesense, "PostgreSQL" => :postgresql,
    "SQLite" => :sqlite, "MySQL" => :mysql, "Redis Search" => :redis_search, "Manticore" => :manticore
  }.freeze

  README_UNITS = { "characters" => [ :characters ], "words" => [ :words ], "none" => [] }.freeze

  test "the README's capability matrix is the one this suite asserts" do
    readme = File.read(File.expand_path("../README.md", __dir__))
    table = readme[/^\| Adapter \| highlight \|.*?(?=\n\n)/m]
    assert table, "the README no longer carries the capability matrix header this test anchors on"

    rows = table.scan(/^\| ([A-Za-z ]+) \| (.+) \|$/).filter_map do |name, cells|
      next if name.strip == "Adapter"
      adapter = README_ADAPTER_NAMES.fetch(name.strip)

      values = cells.split("|").map { |cell| cell.strip.delete("*") }
      assert_equal 9, values.size, "#{name.strip}'s row does not carry the nine value columns this parser reads"

      units = README_UNITS.fetch(values.delete_at(1))
      assert_equal [], values - %w[ yes no ], "#{name.strip}'s row carries a cell this parser cannot read"
      booleans = values.map { |v| v == "yes" }
      [ adapter, {
        highlighting: booleans[0], units: units, markers: booleans[1],
        snippets: booleans[2], operator: booleans[3], missing: booleans[4],
        subfields: booleans[5], string_fields: booleans[6], ranges: booleans[7]
      } ]
    end.to_h

    assert_equal CAPABILITY_MATRIX, rows
  end

  test "the README's verify exit codes are the codes the task returns" do
    table = File.read(File.expand_path("../README.md", __dir__))[/(^\| Code \| Outcome \| Meaning \|.*?)\n\n/m, 1]
    assert table, "the README no longer carries the verify exit code table this test anchors on"
    documented = table.scan(/^\| (\d+) \| (\w+) \|/).to_h { |code, outcome| [ outcome.to_sym, code.to_i ] }

    assert_equal ActiveSearch::Schema::Verification::EXIT_CODES, documented
  end

  test "every Contents link in the README resolves to a heading" do
    readme = File.read(File.expand_path("../README.md", __dir__))
    slugs = readme_heading_slugs(readme)
    links = readme_anchor_links(readme)

    assert_operator slugs.size, :>, 20, "the heading parser found almost none, so a pass would mean nothing"
    assert_operator links.size, :>, 20, "the link parser found almost none, so a pass would mean nothing"

    broken = links.reject { |anchor| slugs.include?(anchor) }
    assert_empty broken, "these anchors match no heading -- a heading was renamed without its links: #{broken.inspect}"
  end

  test "a list routes to the union and a Range is refused" do
    assert_nothing_raised do
      ActiveSearch.index(:records).search("q").filter(account_id: [ 1, 2 ]).to_native_query
    end

    range = assert_raises(ActiveSearch::QueryError) do
      ActiveSearch.index(:records).search("q").filter(account_id: 1..5).to_native_query
    end
    assert_match(/cannot be filtered by a Range/, range.message)

    irreconcilable = assert_raises(ActiveSearch::QueryError) do
      ActiveSearch.index(:records).search("q").filter(account_id: 1).filter(account_id: 2).to_native_query
    end
    assert_match(/no value in common/, irreconcilable.message)
  end

  test "routing reads back what the query resolved to" do
    index = ActiveSearch.index(:records)

    assert_equal 1, index.search("q").filter(account_id: 1).routing
    assert_equal [ 1, 2 ], index.search("q").filter(account_id: [ 1, 2 ]).routing
    assert_nil index.search("q").routing
  end

  private
    def readme_heading_slugs(readme)
      seen = Hash.new(0)

      outside_code_fences(readme).filter_map { |line| line[/^\#{1,6}\s+(.*?)\s*$/, 1] }.map do |heading|
        slug = slugify(inline_text(heading))
        seen[slug] += 1
        # GitHub disambiguates a repeated slug by appending a counter.
        seen[slug] > 1 ? "#{slug}-#{seen[slug] - 1}" : slug
      end.to_set
    end

    def readme_anchor_links(readme)
      outside_code_fences(readme).flat_map { |line| line.scan(/\]\(#([^)]*)\)/).flatten }
    end

    def outside_code_fences(readme)
      fence = nil

      readme.lines.reject do |line|
        marker = line[/^\s*(```+|~~~+)/, 1]
        fence = fence.nil? ? marker[0] : (marker[0] == fence ? nil : fence) if marker
        marker || fence
      end
    end

    def inline_text(markdown)
      markdown.gsub(/`([^`]*)`/, '\1').gsub(/\[([^\]]*)\]\([^)]*\)/, '\1')
        .gsub(/(\*\*|__)(.*?)\1/, '\2').gsub(/(\*|_)(.*?)\1/, '\2').strip
    end

    def slugify(text)
      text.downcase.gsub(/[^\p{Word}\- ]/, "").tr(" ", "-")
    end
end
