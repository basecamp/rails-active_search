require "test_helper"

class RoutingTest < ActiveSupport::TestCase
  class RecordingStore < ActiveSearch::StoreAdapters::Base
    attr_reader :build_routing, :execute_routing

    def build_query(index, query_context, routing: nil)
      @build_routing = routing
      { built: true }
    end

    def search(index, query_context, routing: nil)
      build_query(index, query_context, routing: routing)
      @execute_routing = routing
      { results: [], total: 0 }
    end

    def type_casters
      {}
    end

    def capabilities
      ActiveSearch::Capabilities.new(missing_filters: true)
    end
  end

  setup do
    fields = ActiveSearch::Index::Schema.from_block(
      proc do
        text :title
        integer :account_id
        string :status
      end,
      index_name: :routing_test
    )

    @definition = ActiveSearch::Index::Definition.new(fields: fields)
  end

  test "no route_by resolves to nil" do
    assert_nil resolve(nil, filter: { account_id: 1 })
  end

  test "no predicate on the routing field resolves to nil" do
    assert_nil resolve(:account_id, filter: { status: "open" })
  end

  test "one equality supplies the routing value" do
    assert_equal 1, resolve(:account_id, filter: { account_id: 1 })
  end

  test "repeated equalities that agree supply the value" do
    context = build_context(filter: { account_id: 1 })
      .add_conditions([ condition(:account_id, 1) ])

    assert_equal 1, ActiveSearch::Routing.resolve(:account_id, context)
  end

  test "repeated equalities that conflict raise" do
    context = build_context(filter: { account_id: 1 })
      .add_conditions([ condition(:account_id, 2) ])

    error = assert_raises(ActiveSearch::QueryError) do
      ActiveSearch::Routing.resolve(:account_id, context)
    end

    assert_match(/no value in common/, error.message)
  end

  test "a list on the routing field routes to the union" do
    assert_equal [ 1, 2 ], resolve(:account_id, filter: { account_id: [ 1, 2 ] })
  end

  test "a single-member list resolves to the value" do
    assert_equal 1, resolve(:account_id, filter: { account_id: [ 1 ] })
  end

  test "repeated lists intersect" do
    context = build_context(filter: { account_id: [ 1, 2 ] })
      .add_conditions([ condition(:account_id, [ 2, 3 ]) ])

    assert_equal 2, ActiveSearch::Routing.resolve(:account_id, context)
  end

  test "filters that leave nothing raise, because the query can match nothing" do
    context = build_context(filter: { account_id: [ 1, 2 ] })
      .add_conditions([ condition(:account_id, [ 3 ]) ])

    error = assert_raises(ActiveSearch::QueryError) do
      ActiveSearch::Routing.resolve(:account_id, context)
    end

    assert_match(/no value in common/, error.message)
  end

  test "an empty list on the routing field raises rather than routing nowhere" do
    error = assert_raises(ActiveSearch::QueryError) { resolve(:account_id, filter: { account_id: [] }) }

    assert_match(/no value in common/, error.message)
  end

  test "a range on the routing field raises" do
    error = assert_raises(ActiveSearch::QueryError) do
      resolve(:account_id, filter: { account_id: 1..5 })
    end

    assert_match(/cannot be filtered by a Range/, error.message)
  end

  test "an array on the routing field raises before an empty array matches nothing" do
    assert_raises(ActiveSearch::QueryError) do
      resolve(:account_id, filter: { account_id: [] })
    end
  end

  test "a negated predicate supplies no routing value" do
    assert_nil resolve(:account_id, reject: { account_id: 1 })
  end

  test "a negation on the routing field leaves the query unrouted" do
    assert_nil resolve(:account_id, reject: { account_id: [ 1, 2 ] })
    assert_nil resolve(:account_id, reject: { account_id: 1 })
  end

  test "a negated empty array leaves the query unrouted, like any negation" do
    assert_nil resolve(:account_id, reject: { account_id: [] })
  end

  test "a filter that includes absence leaves the query unrouted" do
    assert_nil routed_relation(RecordingStore.new).filter(account_id: nil).routing
    assert_nil routed_relation(RecordingStore.new).filter(account_id: [ 1, nil ]).routing
  end

  test "a missing-value filter on the routing field is not an unroutable query" do
    assert_nothing_raised { routed_relation(RecordingStore.new).filter(account_id: nil).routing }
  end

  test "a concrete filter still routes alongside one that includes absence" do
    relation = routed_relation(RecordingStore.new).filter(account_id: nil).filter(account_id: 7)

    assert_equal 7, relation.routing
  end

  test "routing reads conditions that the partitions drop as no-ops" do
    context = build_context(reject: { account_id: [] })

    assert_equal [ :account_id ], context.all_conditions.map(&:field)
    assert_empty context.all_conditions.negative
    assert_empty context.all_conditions.positive
  end

  test "a protected value wins over a conflicting caller value" do
    context = build_context(filter: { account_id: 2 })
      .add_protected_conditions([ condition(:account_id, 1) ])

    assert_equal 1, ActiveSearch::Routing.resolve(:account_id, context)
  end

  test "conflicting protected values raise" do
    context = build_context
      .add_protected_conditions([ condition(:account_id, 1), condition(:account_id, 2) ])

    error = assert_raises(ActiveSearch::QueryError) do
      ActiveSearch::Routing.resolve(:account_id, context)
    end

    assert_match(/protected conditions/, error.message)
  end

  test "results and to_native_query resolve the same routing value" do
    store = RecordingStore.new
    relation = routed_relation(store).filter(account_id: 7)

    relation.to_native_query
    build_only = store.build_routing

    relation.results

    assert_equal 7, build_only
    assert_equal 7, store.build_routing
    assert_equal 7, store.execute_routing
  end

  test "#routing answers with the value execution sends" do
    [ 7, [ 7, 8 ] ].each do |value|
      store = RecordingStore.new
      relation = routed_relation(store).filter(account_id: value)

      assert_equal value, relation.routing

      relation.results
      assert_equal value, store.execute_routing, "#routing disagreed with what was sent"
    end
  end

  test "#routing is nil for a query that reads every shard" do
    assert_nil routed_relation(RecordingStore.new).routing
    assert_nil routed_relation(RecordingStore.new).reject(account_id: 1).routing
  end

  test "#routing raises on an unroutable query, the same as executing would" do
    relation = routed_relation(RecordingStore.new).filter(account_id: 1..5)

    assert_raises(ActiveSearch::QueryError) { relation.routing }
  end

  test "to_native_query resolves routing rather than leaving the build path unrouted" do
    store = RecordingStore.new
    routed_relation(store).filter(account_id: 3).to_native_query

    assert_equal 3, store.build_routing
  end

  test "to_native_query raises on an unroutable query just as results does" do
    store = RecordingStore.new
    relation = routed_relation(store).filter(account_id: 1).filter(account_id: 2)

    assert_raises(ActiveSearch::QueryError) { relation.to_native_query }
    assert_raises(ActiveSearch::QueryError) { relation.results }
  end

  private
    def condition(field, value, negated: false)
      ActiveSearch::Conditions::Condition.new(field: field, value: value, negated: negated)
    end

    def build_context(filter: {}, reject: {})
      conditions = ActiveSearch::Conditions.none
      predicates = filter.map { |field, value| condition(field, value) } +
        reject.map { |field, value| condition(field, value, negated: true) }
      conditions = ActiveSearch::Conditions.new(predicates)

      ActiveSearch::QueryContext.new(conditions: conditions)
    end

    def resolve(route_by, **conditions)
      ActiveSearch::Routing.resolve(route_by, build_context(**conditions))
    end

    def routed_index(store)
      index = ActiveSearch::Index.new(:routing_test, definition: @definition, route_by: :account_id)
      index.define_singleton_method(:store) { store }
      index
    end

    def routed_relation(store)
      ActiveSearch::Query.new(index: routed_index(store))
    end
end
