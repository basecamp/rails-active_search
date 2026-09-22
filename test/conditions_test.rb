require "test_helper"

class ConditionsTest < ActiveSupport::TestCase
  def conditions(*specs)
    ActiveSearch::Conditions.new(specs.map { |spec| ActiveSearch::Conditions::Condition.new(**spec) })
  end

  def fields_of(collection)
    collection.map(&:field)
  end

  test "conditions are ordered and repeated fields survive" do
    both_bounds = conditions({ field: :views, value: 100.. }, { field: :views, value: ..200 })

    assert_equal 2, both_bounds.count
    assert_equal [ :views, :views ], fields_of(both_bounds)
    assert_equal [ 100.., ..200 ], both_bounds.map(&:value)
  end

  test "repeated scalars on one field are not collapsed" do
    statuses = conditions({ field: :status, value: "open" }, { field: :status, value: "closed" })

    assert_equal [ "open", "closed" ], statuses.for_field(:status).map(&:value)
  end

  test "positive and negative partition the collection while keeping order" do
    mixed = conditions({ field: :a, value: 1 }, { field: :b, value: 2, negated: true }, { field: :c, value: 3 })

    assert_equal [ :a, :c ], fields_of(mixed.positive)
    assert_equal [ :b ], fields_of(mixed.negative)
  end

  test "concatenation returns a new collection and preserves order" do
    first = conditions({ field: :a, value: 1 })
    second = conditions({ field: :b, value: 2 })

    assert_equal [ :a, :b ], fields_of(first + second)
    assert_equal [ :a ], fields_of(first), "the original was modified"
  end

  test "conditions and their predicates are frozen" do
    frozen = conditions({ field: :a, value: 1 })

    assert_predicate frozen, :frozen?
    assert_predicate frozen.first, :frozen?
  end

  test "a negated empty array is dropped from both partitions and a positive one is kept" do
    dropped = conditions({ field: :a, value: 1 }, { field: :b, value: [], negated: true }, { field: :c, value: 2, negated: true })

    assert_equal [ :a ], fields_of(dropped.positive)
    assert_equal [ :c ], fields_of(dropped.negative)

    kept = conditions({ field: :a, value: [] })
    assert_equal [ :a ], fields_of(kept.positive)
  end

  test "a negated missing-only predicate survives the partition" do
    missing = conditions({ field: :a, value: [], negated: true, include_missing: true })

    assert_equal [ :a ], fields_of(missing.negative)
    assert_predicate missing.first, :missing_only?
  end

  test "for_field selects only the named field" do
    pair = conditions({ field: :a, value: 1 }, { field: :b, value: 2 })

    assert_equal [ 1 ], pair.for_field(:a).map(&:value)
    assert_empty pair.for_field(:missing)
  end

  test "filter refuses a structure that would collapse repeated fields" do
    [ [ [ :account_id, 1 ], [ :account_id, 2 ] ], ActiveSearch::Conditions.new([]) ].each do |not_a_hash|
      error = assert_raises(ActiveSearch::QueryError) { ActiveSearch.index(:articles).filter(not_a_hash) }
      assert_match(/must be given as a Hash/, error.message)
    end
  end

  test "chaining is how a field is repeated, and both predicates survive" do
    query = ActiveSearch.index(:articles).filter(account_id: 1).filter(account_id: 2)

    assert_equal [ :account_id, :account_id ], fields_of(query_context_for(query).all_conditions)
  end

  test "one call naming a field as both a String and a Symbol is refused rather than collapsed" do
    error = assert_raises(ActiveSearch::QueryError) do
      ActiveSearch.index(:articles).filter("status" => "published", status: "draft")
    end

    assert_match(/:status twice/, error.message)
    assert_match(/chaining filter calls/, error.message)
  end

  test "the String and Symbol spellings of a field both survive when chained" do
    query = ActiveSearch.index(:articles).filter("status" => "published").filter(status: "draft")

    assert_equal [ :status, :status ], fields_of(query_context_for(query).all_conditions)
  end

  test "a field named once under one spelling is untouched" do
    query = ActiveSearch.index(:articles).filter(status: "draft")

    assert_equal [ "draft" ], query_context_for(query).all_conditions.for_field(:status).map(&:value)
  end
end
