require "test_helper"

class PublicApiTest < ActiveSupport::TestCase
  searches :articles

  test "Query replaces Relation" do
    assert ActiveSearch.const_defined?(:Query, false)
    assert_not ActiveSearch.const_defined?(:Relation, false),
      "ActiveSearch::Relation was renamed to ActiveSearch::Query and must not survive"
  end

  test "referencing the superseded constant raises rather than resolving" do
    assert_raises(NameError) { ActiveSearch::Relation }
  end

  test "Query keeps the methods the rename does not move" do
    %i[search filter sort hit_fields highlight limit offset results].each do |method|
      assert_includes ActiveSearch::Query.public_instance_methods, method,
        "#{method} is not part of the rename and must keep its name"
    end
  end

  test "Query is not Enumerable" do
    assert_not ActiveSearch::Query.include?(Enumerable)
    assert_not ActiveSearch::Query.public_instance_methods.include?(:each)
  end

  test "Results is Enumerable and keeps its name" do
    assert ActiveSearch.const_defined?(:Results, false)
    assert ActiveSearch::Results.include?(Enumerable)
  end

  test "to_native_query replaces to_query, and native replaces modify_raw_query" do
    %i[to_native_query native].each do |method|
      assert_includes ActiveSearch::Query.public_instance_methods, method
    end

    assert_not_includes ActiveSearch::Query.instance_methods(false), :modify_raw_query,
      "modify_raw_query was renamed to native and must not survive"
  end

  test "a caller reaching for the old to_query hits Active Support, not a NoMethodError" do
    query = ActiveSearch.index(:articles).all

    error = assert_raises(ArgumentError) { query.to_query }
    assert_match(/given 0, expected 1/, error.message)

    assert_kind_of String, query.to_query("k"),
      "Object#to_query with an argument answers silently; that is the hazard"
  end

  test "native requires a block" do
    assert_raises(ActiveSearch::QueryError) { ActiveSearch.index(:articles).all.native }
  end

  test "native is reachable from an index, not only from a query" do
    assert_respond_to ActiveSearch.index(:articles), :to_native_query
    assert_respond_to ActiveSearch.index(:articles), :native
  end

  test "search_index and search_indexes are removed from indexed models" do
    assert_respond_to Article, :search
    assert_not Article.respond_to?(:search_index),
      "search_index was removed in favour of .search and ActiveSearch.index"
    assert_not Article.respond_to?(:search_indexes),
      "search_indexes was removed; it was introspection over private reflections"
  end

  test "an unindexed model gains neither" do
    assert_not Author.respond_to?(:search_index)
    assert_not Author.respond_to?(:search_indexes)
  end

  test "the raw index entry point survives and is not model-scoped" do
    assert_kind_of ActiveSearch::Index, ActiveSearch.index(:articles)
  end

  test "sort_by_relevance replaces sort(Score) and takes no direction" do
    assert_includes ActiveSearch::Query.public_instance_methods, :sort_by_relevance
    assert_equal 0, ActiveSearch::Query.instance_method(:sort_by_relevance).arity
  end

  test "Score is private: the :: path raises, const_get still reaches it" do
    error = assert_raises(NameError) { ActiveSearch::Score }
    assert_match(/private constant/, error.message)

    assert_not_includes ActiveSearch.constants, :Score

    assert_kind_of Module, ActiveSearch.const_get(:Score),
      "private_constant does not block const_get; the test says so rather than implying otherwise"
  end

  SCORE_ORDER_BASELINE = {
    sqlite: "ORDER BY score LIMIT 25",
    mysql: "ORDER BY score DESC LIMIT 25",
    postgresql: "ORDER BY score DESC LIMIT 25"
  }.freeze

  test "sort_by_relevance compiles the same order clause sort(Score) did" do
    expected = SCORE_ORDER_BASELINE[store_adapter_name]
    skip "no recorded baseline for #{store_adapter_name}" unless expected

    native = ActiveSearch.index(:articles).search("ruby").sort_by_relevance.to_native_query

    assert_equal expected, native.to_sql[/ORDER BY.*/],
      "a pure rename must not move the order clause"
  end

  test "search takes at most one positional argument" do
    assert_equal(-1, ActiveSearch::Query.instance_method(:search).arity)

    params = ActiveSearch::Query.instance_method(:search).parameters
    positional = params.select { |kind, _| kind == :opt || kind == :req }

    assert_equal 1, positional.size, "fields are selected through fields:, not positionally"
    assert_includes params, [ :key, :fields ]
    assert_includes params, [ :key, :operator ]
  end

  test "the positional field form is rejected rather than reinterpreted" do
    assert_raises(ArgumentError) { ActiveSearch.index(:articles).search("ruby", [ :title ]) }
  end

  test "missing, nil, empty and whitespace-only text all produce a filter-only query" do
    [ nil, "", "   ", "\t
 " ].each do |blank|
      query = ActiveSearch.index(:articles).search(blank)
      assert_nil query_context_for(query).query, "#{blank.inspect} should mean no text"
    end

    assert_nil query_context_for(ActiveSearch.index(:articles).search).query
  end

  test "search text must be a String or nil" do
    [ 42, :ruby, [ "ruby" ], { q: "ruby" } ].each do |value|
      error = assert_raises(ActiveSearch::QueryError) { ActiveSearch.index(:articles).search(value) }
      assert_match(/must be a String or nil/, error.message)
    end
  end

  test "text is kept verbatim apart from the blank check" do
    assert_equal "  ruby  ", query_context_for(ActiveSearch.index(:articles).search("  ruby  ")).query
  end

  test "the module-level default_limit accessors are removed" do
    assert_not ActiveSearch.respond_to?(:default_limit),
      "runtime configuration lives on config.active_search"
    assert_not ActiveSearch.respond_to?(:default_limit=)
  end

  test "the default lives on the Rails configuration object and ships as 25" do
    assert_equal 25, Rails.application.config.active_search.default_limit
  end

  def effective_limit(query)
    query.send(:query_context_with_defaults).limit
  end

  test "an unset limit takes the configured default" do
    assert_equal 25, effective_limit(ActiveSearch.index(:articles).search("ruby"))
  end

  test "limit(nil) is explicitly unlimited and drops the default" do
    assert_nil effective_limit(ActiveSearch.index(:articles).search("ruby").limit(nil)),
      "limit(nil) must opt out of the default rather than re-request it"
  end

  test "limit(0) still means zero rows, not unlimited" do
    assert_equal 0, effective_limit(ActiveSearch.index(:articles).search("ruby").limit(0))
  end

  test "limit(nil) gives to_native_query a scope with no limit to strip" do
    skip "to_native_query is not an ActiveRecord relation on #{store_adapter_name}" unless
      %i[sqlite mysql postgresql].include?(store_adapter_name)

    default_scope = ActiveSearch.index(:articles).search("ruby").to_native_query
    assert_equal 25, default_scope.limit_value,
      "control: without limit(nil) the scope carries the default"

    scope = ActiveSearch.index(:articles).search("ruby").limit(nil).to_native_query

    assert_kind_of ActiveRecord::Relation, scope
    assert_nil scope.limit_value
    assert_nil scope.offset_value
  end

  test "string replaces keyword in the DSL, with no alias retained" do
    schema = ActiveSearch::Index::Schema.new

    assert_respond_to schema, :string
    assert_not schema.respond_to?(:keyword),
      "keyword was renamed to string and must not survive as an alias"
  end

  test "keyword is not a valid field type" do
    assert_includes ActiveSearch::Index::Field::VALID_TYPES, :string
    assert_not_includes ActiveSearch::Index::Field::VALID_TYPES, :keyword

    assert_raises(ActiveSearch::ConfigurationError) { ActiveSearch::Index::Field.new(:status, :keyword) }
  end

  test "the caster registry is keyed by string, not keyword" do
    assert ActiveSearch::Index::Field::CASTERS.key?(:string)
    assert_not ActiveSearch::Index::Field::CASTERS.key?(:keyword)
  end

  test "string reuses Active Record's String caster" do
    assert_instance_of ActiveSearch::Type::String, ActiveSearch::Index::Field::CASTERS[:string]
  end

  test "declaring a keyword field in a block raises" do
    assert_raises(NoMethodError) do
      ActiveSearch::Index::Schema.from_block(proc { keyword :status }, index_name: :probe)
    end
  end

  test "the nested modules moved with the class" do
    assert ActiveSearch::Query.const_defined?(:Normalization)
    assert ActiveSearch::Query.const_defined?(:Validation)
  end

  test "reject replaces the filter.not proxy, which is removed" do
    assert_includes ActiveSearch::Query.public_instance_methods, :reject
    assert_not ActiveSearch::Query.const_defined?(:FilterChain, false),
      "the filter.not proxy was temporary and must not survive"
  end

  test "filter requires conditions rather than returning a proxy" do
    assert_raises(ArgumentError) { ActiveSearch.index(:articles).all.filter }
  end

  test "reject is available on an index as well as a query" do
    assert_respond_to ActiveSearch.index(:articles), :reject
  end

  test "register_adapter is public API" do
    assert_respond_to ActiveSearch, :register_adapter
    assert_equal 2, ActiveSearch.method(:register_adapter).arity
  end
end
