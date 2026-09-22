require "test_helper"

class MissingFiltersTest < ActiveSupport::TestCase
  searches :articles

  def supports_missing_filters?
    capabilities.supports_missing_filters?
  end

  setup do
    @with_status = Article.create!(title: "Present", content: "Shared", account_id: 1, status: "published")
    @without_status = Article.create!(title: "Absent", content: "Shared", account_id: 1, status: nil)

    [ @with_status, @without_status ].each { |r| ActiveSearch.index(:articles).add(r) }
  end

  test "capability is declared for every adapter" do
    expected = !%i[typesense manticore].include?(store_adapter_name)

    assert_equal expected, supports_missing_filters?
  end

  test "an unsupported adapter raises rather than dropping the predicate" do
    skip "adapter supports missing filters" if supports_missing_filters?

    assert_raises(ActiveSearch::UnsupportedOperationError) { ActiveSearch.index(:articles).filter(status: nil) }
    assert_raises(ActiveSearch::UnsupportedOperationError) { ActiveSearch.index(:articles).filter(status: [ "published", nil ]) }
    assert_raises(ActiveSearch::UnsupportedOperationError) { ActiveSearch.index(:articles).reject(status: nil) }
  end

  test "UnsupportedOperationError is rescuable as a QueryError" do
    skip "adapter supports missing filters" if supports_missing_filters?

    assert_raises(ActiveSearch::QueryError) { ActiveSearch.index(:articles).filter(status: nil) }
  end

  test "a scalar nil matches absent fields" do
    skip "adapter has no missing filters" unless supports_missing_filters?

    assert_results [ @with_status, @without_status ], ActiveSearch.index(:articles).search("Shared"),
      "control: both documents are in the index"

    assert_results @without_status, ActiveSearch.index(:articles).search("Shared").filter(status: nil)
  end

  test "a rejected scalar nil matches present fields" do
    skip "adapter has no missing filters" unless supports_missing_filters?

    assert_results @with_status, ActiveSearch.index(:articles).search("Shared").reject(status: nil)
  end

  test "a nil array member adds absence to the alternatives" do
    skip "adapter has no missing filters" unless supports_missing_filters?

    assert_results [ @with_status, @without_status ],
      ActiveSearch.index(:articles).search("Shared").filter(status: [ "published", nil ])
  end

  test "a nil array member with a non-matching value matches only absence" do
    skip "adapter has no missing filters" unless supports_missing_filters?

    assert_results @without_status,
      ActiveSearch.index(:articles).search("Shared").filter(status: [ "archived", nil ])
  end

  test "rejecting a nil array member requires presence and inequality" do
    skip "adapter has no missing filters" unless supports_missing_filters?

    assert_results [], ActiveSearch.index(:articles).search("Shared").reject(status: [ "published", nil ])

    assert_results @with_status,
      ActiveSearch.index(:articles).search("Shared").reject(status: [ "archived", nil ])
  end

  test "an array of only nil reduces to the scalar case" do
    skip "adapter has no missing filters" unless supports_missing_filters?

    assert_results @without_status, ActiveSearch.index(:articles).search("Shared").filter(status: [ nil ])
  end

  test "duplicate nil members collapse" do
    skip "adapter has no missing filters" unless supports_missing_filters?

    assert_results @without_status, ActiveSearch.index(:articles).search("Shared").filter(status: [ nil, nil ])
  end

  test "a nil Range endpoint is unbounded and not a missing filter" do
    old = Article.create!(title: "Old", content: "Ranged", account_id: 5, status: "published")
    new = Article.create!(title: "New", content: "Ranged", account_id: 50, status: "published")

    [ old, new ].each { |r| ActiveSearch.index(:articles).add(r) }

    assert_results new, ActiveSearch.index(:articles).search("Ranged").filter(account_id: 10..)
    assert_results old, ActiveSearch.index(:articles).search("Ranged").filter(account_id: ..10)
  end

  test "an endless Range does not require missing-filter capability" do
    assert_nothing_raised { ActiveSearch.index(:articles).filter(account_id: 10..) }
    assert_nothing_raised { ActiveSearch.index(:articles).filter(account_id: ..10) }
  end
end
