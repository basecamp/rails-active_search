require "test_helper"

class MultiValueStorageTest < ActiveSupport::TestCase
  searches :topics

  setup do
    @index = ActiveSearch.index(:topics)
  end

  def topic(subject, folder_ids: [], labels: [], seen_at: [], account_id: 1)
    Topic.create!(subject: subject, folder_ids: folder_ids, labels: labels, seen_at: seen_at,
      account_id: account_id).tap do |record|
      @index.add(record)
    end
    ensure
      @index.store.refresh(:topics) rescue nil
  end

  test "a collection comes back as a collection, not as its inspect output" do
    topic("Planning", folder_ids: [ 4, 9 ])

    hit = @index.search("Planning").results.first.hit

    assert_equal [ 4, 9 ], hit.fields[:folder_ids]
  end

  test "an empty collection comes back empty rather than absent" do
    skip "Solr cannot distinguish an empty collection from an absent field" if store_adapter_name == :solr

    topic("Unfiled", folder_ids: [])

    assert_equal [], @index.search("Unfiled").results.first.hit.fields[:folder_ids]
  end

  test "order and duplicates survive the store" do
    skip "Manticore stores an integer collection as an MVA, which sorts and deduplicates" if
      store_adapter_name == :manticore

    topic("Repeats", folder_ids: [ 3, 1, 3 ])

    assert_equal [ 3, 1, 3 ], @index.search("Repeats").results.first.hit.fields[:folder_ids]
  end

  test "a string collection round trips too" do
    topic("Tagged", labels: %w[urgent later])

    assert_equal %w[urgent later], @index.search("Tagged").results.first.hit.fields[:labels]
  end

  test "a datetime collection round trips and filters" do
    seen = Time.utc(2026, 3, 1, 12, 0, 0)
    other = Time.utc(2026, 4, 1, 12, 0, 0)
    watched = topic("Watched", seen_at: [ seen, other ])
    topic("Ignored", seen_at: [ other ])

    assert_results watched, @index.filter(seen_at: seen)
  end

  test "one value matches a collection that holds it among others" do
    filed = topic("Filed", folder_ids: [ 4, 9 ])
    topic("Elsewhere", folder_ids: [ 7 ])

    assert_results filed, @index.filter(folder_ids: 4)
  end

  test "several values match a collection holding any of them" do
    four = topic("Four", folder_ids: [ 4 ])
    nine = topic("Nine", folder_ids: [ 9 ])
    topic("Seven", folder_ids: [ 7 ])

    assert_results [ four, nine ], @index.filter(folder_ids: [ 4, 9 ])
  end

  test "an empty collection matches nothing" do
    topic("Unfiled", folder_ids: [])

    assert_results [], @index.filter(folder_ids: 4)
  end

  test "reject excludes a collection that holds the value" do
    topic("Filed", folder_ids: [ 4, 9 ])
    elsewhere = topic("Elsewhere", folder_ids: [ 7 ])

    assert_results elsewhere, @index.filter(account_id: 1).reject(folder_ids: 4)
  end

  test "a string collection filters the same way" do
    urgent = topic("Urgent", labels: %w[urgent later])
    topic("Calm", labels: %w[someday])

    assert_results urgent, @index.filter(labels: "urgent")
  end

  HOSTILE = [
    "plain",
    "quote'value",
    "a\" OR \"1\"=\"1",
    "semi;colon",
    "pipe|value",
    "brace}value",
    "back\\slash",
    "per%cent"
  ].freeze

  test "a value that is syntax to the backend is stored and matched as text" do
    HOSTILE.each do |value|
      Topic.delete_all
      wanted = topic("Hostile", labels: [ value, "other" ])
      topic("Decoy", labels: [ "other" ])

      assert_results wanted, @index.filter(labels: value), "filtering for #{value.inspect}"
    end
  end

  test "a collection round trips a value that is syntax to the backend" do
    topic("Hostile", labels: HOSTILE)

    assert_equal HOSTILE, @index.search("Hostile").results.first.hit.fields[:labels]
  end

  test "a range matches a collection holding an element inside it" do
    skip "store cannot range over a collection" unless
      ActiveSearch.index(:topics).capabilities.supports_collection_ranges?

    inside = topic("Inside", folder_ids: [ 1, 50 ])
    topic("Outside", folder_ids: [ 80, 90 ])

    assert_results inside, @index.filter(folder_ids: 40..60)
  end

  test "a range matches nothing when no element falls inside it" do
    skip "store cannot range over a collection" unless
      ActiveSearch.index(:topics).capabilities.supports_collection_ranges?

    topic("Inside", folder_ids: [ 1, 50 ])

    assert_results [], @index.filter(folder_ids: 4..9)
  end

  test "an endless range over a collection is unbounded above" do
    skip "store cannot range over a collection" unless
      ActiveSearch.index(:topics).capabilities.supports_collection_ranges?

    high = topic("High", folder_ids: [ 90 ])
    topic("Low", folder_ids: [ 1 ])

    assert_results high, @index.filter(folder_ids: 60..)
  end

  test "an exclusive range matches on the element inside it" do
    skip "store cannot range over a collection" unless
      ActiveSearch.index(:topics).capabilities.supports_collection_ranges?

    middle = topic("Middle", folder_ids: [ 1, 5, 50 ])
    topic("Far", folder_ids: [ 80, 90 ])

    assert_results middle, @index.filter(folder_ids: 2...10)
  end

  test "an exclusive range matches nothing when the bounds are met by different elements" do
    skip "store cannot range over a collection" unless
      ActiveSearch.index(:topics).capabilities.supports_collection_ranges?

    topic("Middle", folder_ids: [ 1, 5, 50 ])

    assert_results [], @index.filter(folder_ids: 6...50)
  end

  test "reject excludes a collection holding an element inside the range" do
    skip "store cannot range over a collection" unless
      ActiveSearch.index(:topics).capabilities.supports_collection_ranges?

    topic("Middle", folder_ids: [ 1, 5, 50 ])
    far = topic("Far", folder_ids: [ 80, 90 ])

    assert_results far, @index.filter(account_id: 1).reject(folder_ids: 2..10)
  end

  test "a beginless range over a collection is unbounded below" do
    skip "store cannot range over a collection" unless
      ActiveSearch.index(:topics).capabilities.supports_collection_ranges?

    low = topic("Low", folder_ids: [ 1, 50 ])
    topic("High", folder_ids: [ 80, 90 ])

    assert_results low, @index.filter(folder_ids: ..2)
  end

  test "a store that cannot range over a collection says so rather than answering wrongly" do
    skip "store supports collection ranges" if
      ActiveSearch.index(:topics).capabilities.supports_collection_ranges?

    assert_raises(ActiveSearch::UnsupportedOperationError) { @index.filter(folder_ids: 40..60) }
  end

  test "a single-value field on the same index reads as IN, being the same intersection" do
    one = topic("One", account_id: 1)
    two = topic("Two", account_id: 2)
    topic("Three", account_id: 3)

    assert_results [ one, two ], @index.filter(account_id: [ 1, 2 ])
  end
end
