require "test_helper"

class RejectTest < ActiveSupport::TestCase
  searches :articles

  setup do
    @both = article(status: "published", featured: true)
    @status_only = article(status: "published", featured: false)
    @featured_only = article(status: "draft", featured: true)
    @neither = article(status: "draft", featured: false)
    refresh
  end

  test "several conditions are one conjunction to negate" do
    assert_results [ @status_only, @featured_only, @neither ],
      index.reject(status: "published", featured: true)
  end

  test "reject is exactly the documents filter would not have kept" do
    kept = index.filter(status: "published", featured: true).results.map(&:id)
    rejected = index.reject(status: "published", featured: true).results.map(&:id)

    assert_equal [ @both.id ], kept
    assert_equal (all_ids - kept).sort, rejected.sort
  end

  test "chaining negates each condition separately" do
    assert_results [ @neither ], index.reject(status: "published").reject(featured: true)
  end

  test "one condition is unchanged" do
    assert_results [ @featured_only, @neither ], index.reject(status: "published")
  end

  test "one field with several values excludes each of them" do
    assert_results [ @featured_only, @neither ], index.reject(status: %w[ published archived ])
  end

  test "a group beside a reject still ANDs" do
    assert_results [ @both, @featured_only ],
      index.reject(status: "published", featured: false).filter_any([ { featured: true }, { status: "x" } ])
  end

  test "a document missing a compared field is rejected the same everywhere" do
    clear_index
    missing_status = article(status: nil, featured: true)
    missing_featured = article(status: "published", featured: nil)
    missing_both = article(status: nil, featured: false)
    matches = article(status: "published", featured: true)
    refresh

    assert_results [ matches ], index.filter(status: "published", featured: true)
    assert_results [ missing_status, missing_featured, missing_both ],
      index.reject(status: "published", featured: true)
  end

  test "a single condition rejects a document missing the field, the same everywhere" do
    clear_index
    missing_status = article(status: nil, featured: true)
    present = article(status: "published", featured: true)
    refresh

    assert_results [ present ], index.filter(status: "published")
    assert_results [ missing_status ], index.reject(status: "published")
  end

  test "a value list that cannot hold makes the whole rejection a no-op" do
    assert_results [ @both, @status_only, @featured_only, @neither ],
      index.reject(status: [], featured: true)
  end

  test "a range inside a rejection negates as a range" do
    assert_results [ @featured_only, @neither ], index.reject(status: "published", account_id: 1..5)
  end

  test "a missing-value predicate keeps its meaning inside a rejection" do
    skip "store does not support missing-value filters" unless
      ActiveSearch.index(:articles).capabilities.supports_missing_filters?

    clear_index
    absent = article(status: nil, featured: true)
    present = article(status: "published", featured: true)
    refresh

    assert_results [ absent ], index.filter(status: nil, featured: true)
    assert_results [ present ], index.reject(status: nil, featured: true)
  end

  private
    def index
      ActiveSearch.index(:articles)
    end

    def all_ids
      [ @both, @status_only, @featured_only, @neither ].map(&:id)
    end

    def article(**attributes)
      Article.create!(title: "Reject", content: "body", account_id: 1, **attributes)
        .tap { |record| index.add(record) }
    end

    def clear_index
      [ @both, @status_only, @featured_only, @neither ].each { |record| index.remove(record) }
      refresh
    end

    def refresh
      index.store.refresh(:articles)
    rescue StandardError
      nil
    end
end
