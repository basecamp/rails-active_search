require "test_helper"

class FilterAnyTest < ActiveSupport::TestCase
  searches :articles, :records, :comments, :topics

  setup do
    @published = article(status: "published", account_id: 1, featured: false)
    @featured = article(status: "draft", account_id: 2, featured: true)
    @both = article(status: "published", account_id: 2, featured: true)
    @neither = article(status: "draft", account_id: 3, featured: false)
    refresh
  end

  test "alternatives on different fields match either" do
    assert_results [ @published, @both, @featured ],
      index.filter_any([ { status: "published" }, { featured: true } ])
  end

  test "an alternative with several conditions ANDs within itself" do
    assert_results [ @both, @neither ],
      index.filter_any([ { status: "published", featured: true }, { account_id: 3 } ])
  end

  test "a group ANDs with the filters beside it" do
    assert_results [ @both ],
      index.filter(account_id: 2).filter_any([ { status: "published" }, { account_id: 99 } ])
  end

  test "two groups AND with each other" do
    assert_results [ @both ],
      index.filter_any([ { status: "published" }, { account_id: 99 } ])
        .filter_any([ { featured: true }, { account_id: 99 } ])
  end

  test "one alternative is the same as filtering on it" do
    assert_results [ @published, @both ], index.filter_any([ { status: "published" } ])
  end

  test "no alternatives matches nothing" do
    assert_results [], index.filter_any([])
    assert_results [], index.filter(account_id: 1).filter_any([])

    assert_results [ @published, @both ], index.filter_any([ { status: "published" } ])
    assert_results [ @published, @featured, @both, @neither ], index.filter({})
  end

  test "an alternative that matches nothing drops out of the group" do
    assert_results [ @featured, @both ], index.filter_any([ { account_id: [] }, { featured: true } ])
  end

  test "an alternative holding only an unbounded range makes the group match everything" do
    assert_results [ @published, @featured, @both, @neither ],
      index.filter_any([ { account_id: nil..nil }, { status: "published" } ])

    assert_results [ @featured, @both ],
      index.filter(account_id: 2).filter_any([ { account_id: nil..nil }, { status: "published" } ])
  end

  test "a group routes when every alternative names the routing field" do
    assert_equal 1, records.filter_any([ { account_id: 1, record_type: "Comment" },
                                         { account_id: 1, record_type: "Post" } ]).routing

    assert_equal [ 1, 2 ], records.filter_any([ { account_id: 1 }, { account_id: 2 } ]).routing
  end

  test "a loose alternative wins over one the shards cannot be read from" do
    loose = { record_type: "Post" }
    ranged = { account_id: 1..5 }

    assert_nil records.filter_any([ ranged, loose ]).routing
    assert_nil records.filter_any([ loose, ranged ]).routing
  end

  test "a range decides nothing when every alternative names the field" do
    assert_raises(ActiveSearch::QueryError) do
      records.filter_any([ { account_id: 1..5 }, { account_id: 7 } ]).routing
    end
  end

  test "a group does not route when an alternative leaves the field open" do
    assert_nil records.filter_any([ { account_id: 1 }, { record_type: "Post" } ]).routing
    assert_nil records.filter_any([ { record_type: "Post" }, { record_type: "Comment" } ]).routing
  end

  test "a group's shards intersect a filter beside it" do
    group = [ { account_id: 1 }, { account_id: 2 } ]

    assert_equal 1, records.filter(account_id: 1).filter_any(group).routing
    assert_equal 3, records.filter(account_id: 3).filter_any([ { account_id: 3 } ]).routing
  end

  test "a filter beside a group that shares no shard cannot match" do
    assert_raises(ActiveSearch::QueryError) do
      records.filter(account_id: 9).filter_any([ { account_id: 1 }, { account_id: 2 } ]).routing
    end
  end

  test "a branch can hold a range" do
    assert_results [ @published, @featured, @both ], index.filter_any([ { account_id: 1..2 } ])
  end

  test "a branch can hold a list of values" do
    assert_results [ @published, @both ], index.filter_any([ { status: %w[ published archived ] } ])
  end

  test "a branch can hold a collection field, which overlaps rather than equals" do
    topics = ActiveSearch.index(:topics)
    filed = Topic.create!(subject: "Filed", folder_ids: [ 4, 9 ], account_id: 1)
    labelled = Topic.create!(subject: "Labelled", folder_ids: [ 7 ], labels: %w[ urgent ], account_id: 1)
    Topic.create!(subject: "Neither", folder_ids: [ 8 ], account_id: 1)
    [ filed, labelled, Topic.last ].each { |record| topics.add(record) }
    topics.store.refresh(:topics) rescue nil

    assert_results [ filed, labelled ], topics.filter_any([ { folder_ids: 4 }, { labels: "urgent" } ])
  end

  test "a branch can ask for a field to be absent" do
    skip "store does not support missing-value filters" unless supports_missing?

    absent = article(status: nil, account_id: 4, featured: false)
    refresh

    assert_results [ absent, @featured, @both ],
      index.filter_any([ { status: nil }, { featured: true } ])
  end

  test "a branch can ask for a value or absence together" do
    skip "store does not support missing-value filters" unless supports_missing?

    absent = article(status: nil, account_id: 4, featured: false)
    refresh

    assert_results [ @published, @both, absent ],
      index.filter_any([ { status: [ "published", nil ] } ])
  end

  test "a bare Hash is refused, because it reads as one alternative" do
    error = assert_raises(ActiveSearch::QueryError) { index.filter_any(status: "published") }

    assert_match(/Array of Hashes/, error.message)
  end

  test "an alternative with no conditions is refused, and the message says what to write" do
    [ [ {} ], [ {}, { status: "published" } ] ].each do |branches|
      error = assert_raises(ActiveSearch::QueryError) { index.filter_any(branches) }

      assert_match(/matches every document/, error.message)
      assert_match(/\{ status: \[\] \}/, error.message)
    end
  end

  test "an unknown field inside an alternative is refused like any other filter" do
    assert_raises(ActiveSearch::QueryError) { index.filter_any([ { nonexistent: 1 } ]) }
  end

  private
    def index
      ActiveSearch.index(:articles)
    end

    def records
      ActiveSearch.index(:records)
    end

    def supports_missing?
      index.capabilities.supports_missing_filters?
    end

    def article(**attributes)
      Article.create!(title: "Any", content: "body", **attributes).tap { |record| index.add(record) }
    end

    def refresh
      index.store.refresh(:articles)
    rescue StandardError
      nil
    end
end
