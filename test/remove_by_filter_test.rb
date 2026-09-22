require "test_helper"

class RemoveByFilterTest < ActiveSupport::TestCase
  searches :articles, :records, :comments

  setup do
    @keep = Article.create!(title: "Kept article", content: "shared", account_id: 1)
    @drop_one = Article.create!(title: "Dropped one", content: "shared", account_id: 2)
    @drop_two = Article.create!(title: "Dropped two", content: "shared", account_id: 2)
    [ @keep, @drop_one, @drop_two ].each { |article| index.add(article) }
    refresh
  end

  test "removes every document matching the filter and leaves the rest" do
    assert_equal 3, index.search("shared").results.total, "control: all three are indexed"

    removed = index.remove_by_filter(account_id: 2)
    refresh

    assert_equal 2, removed
    assert_results @keep, index.search("shared")
  end

  test "takes the whole filter grammar, not just equality" do
    removed = index.remove_by_filter(account_id: 2..2)
    refresh

    assert_equal 2, removed
    assert_results @keep, index.search("shared")
  end

  test "an array filter removes each match" do
    index.remove_by_filter(account_id: [ 1, 2 ])
    refresh

    assert_results [], index.search("shared")
  end

  test "an empty filter raises rather than emptying the index" do
    [ {}, nil ].each do |empty|
      assert_raises(ActiveSearch::QueryError, "#{empty.inspect} must not delete everything") do
        index.remove_by_filter(empty)
      end
    end

    refresh
    assert_equal 3, index.search("shared").results.total, "nothing was removed"
  end

  test "an undeclared field is refused, as it is for a search" do
    assert_raises(ActiveSearch::QueryError) { index.remove_by_filter(nonexistent: 1) }
  end

  test "reports what it removed through a notification" do
    events = []
    callback = ->(*args) { events << ActiveSupport::Notifications::Event.new(*args) }

    ActiveSupport::Notifications.subscribed(callback, "remove_by_filter.active_search") do
      index.remove_by_filter(account_id: 2)
    end

    assert_equal 1, events.size
    assert_equal :articles, events.first.payload[:index]
    assert_equal 2, events.first.payload[:removed]
  end

  test "no rows are left behind in a side table" do
    skip "only SQLite keeps a side table" unless store_adapter_name == :sqlite

    model = index.store.send(:model_for, index)
    fts_count = -> { model.connection.select_value("SELECT COUNT(*) FROM #{model.table_name}_fts") }

    assert_equal 3, model.count
    assert_equal 3, fts_count.call, "control: a row per document"

    index.remove_by_filter(account_id: [ 1, 2 ])

    assert_equal 0, model.count
    assert_equal 0, fts_count.call, "the side table kept its rows"
  end

  test "a routed index removes by filter on the routing field" do
    routed = ActiveSearch.index(:records)
    mine = Comment.create!(body: "shared routed mine", account_id: 7)
    theirs = Comment.create!(body: "shared routed theirs", account_id: 8)
    [ mine, theirs ].each { |comment| routed.add(comment) }
    refresh_routed

    assert_equal 1, routed.remove_by_filter(account_id: 7)
    refresh_routed

    assert_equal [ theirs.id ], routed.search("shared").results.map(&:id)
  end

  test "a routed index removes by filter on a list, and refuses a Range" do
    routed = ActiveSearch.index(:records)
    seven = Comment.create!(body: "shared routed seven", account_id: 7)
    eight = Comment.create!(body: "shared routed eight", account_id: 8)
    nine = Comment.create!(body: "shared routed nine", account_id: 9)
    [ seven, eight, nine ].each { |comment| routed.add(comment) }
    refresh_routed

    assert_equal 2, routed.remove_by_filter(account_id: [ 7, 8 ])
    refresh_routed
    assert_equal [ nine.id ], routed.search("shared").results.map(&:id)

    error = assert_raises(ActiveSearch::QueryError) { routed.remove_by_filter(account_id: 1..5) }
    assert_match(/cannot be filtered by a Range/, error.message)
  end

  test "a routed index removes by filter on a non-routing field" do
    routed = ActiveSearch.index(:records)
    comment = Comment.create!(body: "shared unrouted", account_id: 9)
    routed.add(comment)
    refresh_routed

    assert_equal 1, routed.remove_by_filter(record_type: "Comment")
    refresh_routed

    assert_empty routed.search("shared").results.to_a
  end

  private
    def refresh_routed
      ActiveSearch.index(:records).store.refresh(:records)
    rescue StandardError
      nil
    end

    def index
      ActiveSearch.index(:articles)
    end

    def refresh
      index.store.refresh(:articles)
    rescue StandardError
      nil
    end
end
