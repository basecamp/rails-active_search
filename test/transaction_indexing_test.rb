require "test_helper"

class TransactionIndexingTest < ActiveSupport::TestCase
  searches :comments, :records

  def counting
    counts = Hash.new(0)
    subscription = ActiveSupport::Notifications.subscribe(/\.active_search$/) do |name, *|
      counts[$1] += 1 if name =~ /^(add|remove)\.active_search$/
    end
    yield counts
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription)
  end

  def writes(&block)
    counting { |counts| block.call; counts }
  end

  test "an outer save survives an inner savepoint rollback" do
    comment = Comment.create!(body: "seed", account_id: 1)

    got = writes do
      Comment.transaction do
        comment.update!(body: "outer")
        Comment.transaction(requires_new: true) do
          comment.update!(body: "inner")
          raise ActiveRecord::Rollback
        end
      end
    end

    assert_equal 2, got["add"], "the committed outer save indexes both indexes, once each: #{got.inspect}"
  end

  test "a save made only inside a rolled-back savepoint does not index" do
    comment = Comment.create!(body: "seed", account_id: 1)

    got = writes do
      Comment.transaction do
        Comment.transaction(requires_new: true) do
          comment.update!(body: "inner")
          raise ActiveRecord::Rollback
        end
      end
    end

    assert_equal 0, got["add"], "a rolled-back save must not index: #{got.inspect}"
  end

  test "a released savepoint's save indexes at the real commit, not at release" do
    comment = Comment.create!(body: "seed", account_id: 1)

    counting do |counts|
      Comment.transaction do
        Comment.transaction(requires_new: true) { comment.update!(body: "kept") }
        assert_equal 0, counts["add"], "must not index at savepoint release: #{counts.inspect}"
      end
      assert_equal 2, counts["add"], "must index both indexes once at the real commit: #{counts.inspect}"
    end
  end

  test "two saves in one transaction index once per index, at the commit" do
    comment = Comment.create!(body: "seed", account_id: 1)

    counting do |counts|
      Comment.transaction do
        comment.update!(body: "a")
        comment.update!(body: "b")
        assert_equal 0, counts["add"], "must not index before commit: #{counts.inspect}"
      end
      assert_equal 2, counts["add"], "Comment has two indexes; one write each: #{counts.inspect}"
    end
  end

  test "two instances of one row index once, and neither retains the transaction" do
    comment = Comment.create!(body: "seed", account_id: 1)
    first = Comment.find(comment.id)
    second = Comment.find(comment.id)

    got = writes do
      Comment.transaction do
        first.update!(body: "one")
        second.update!(body: "two")
      end
    end

    assert_equal 2, got["add"], "one write per index, not per instance: #{got.inspect}"

    [ first, second ].each do |instance|
      map = instance.instance_variable_get(:@_active_search_intents)
      assert map.nil? || map.empty?, "no instance may retain intent after the transaction: #{map.inspect}"
    end
  end

  test "an outer rollback clears intent a released savepoint recorded" do
    comment = Comment.create!(body: "seed", account_id: 1)

    Comment.transaction do
      comment.update!(body: "outer")
      Comment.transaction(requires_new: true) { comment.update!(body: "released") }
      raise ActiveRecord::Rollback
    end

    leaked = writes { Comment.suppress_indexing { comment.update!(body: "later") } }
    assert_equal 0, leaked["add"], "no intent may survive the rollback: #{leaked.inspect}"
  end

  test "a rolled-back savepoint holding a released nested one leaves no intent" do
    comment = Comment.create!(body: "seed", account_id: 1)

    Comment.transaction do
      Comment.transaction(requires_new: true) do
        comment.update!(body: "middle")
        Comment.transaction(requires_new: true) { comment.update!(body: "released") }
        raise ActiveRecord::Rollback
      end
    end

    leaked = writes { Comment.suppress_indexing { comment.update!(body: "later") } }
    assert_equal 0, leaked["add"], "no intent may survive: #{leaked.inspect}"
  end

  test "a write that raises clears intent on the raising instance" do
    comment = Comment.create!(body: "seed", account_id: 1)
    comment.singleton_class.prepend(Module.new { def reindex; raise "store down"; end })

    assert_raises(RuntimeError) { comment.update!(body: "raises") }

    assert_nil comment.instance_variable_get(:@_active_search_intents),
      "the intent map must be cleared before the write, even when it raises"
  end

  test "a save outside any transaction indexes at once" do
    comment = Comment.create!(body: "seed", account_id: 1)

    got = writes { comment.update!(body: "plain") }

    assert_equal 2, got["add"], got.inspect
  end

  test "a destroy removes, and a destroy in a rolled-back savepoint does not" do
    comment = Comment.create!(body: "seed", account_id: 1)
    removed = writes { comment.destroy }
    assert_equal 2, removed["remove"], "a destroy removes from both indexes: #{removed.inspect}"

    other = Comment.create!(body: "seed2", account_id: 1)
    got = writes do
      Comment.transaction do
        Comment.transaction(requires_new: true) { other.destroy; raise ActiveRecord::Rollback }
      end
    end
    assert_equal 0, got["remove"], "a rolled-back destroy must not remove: #{got.inspect}"
  end

  test "a touch indexes the asking index, and a rolled-back touch does not" do
    original = Comment._index_reflections
    Comment.has_search(index: :comments, **original.fetch(:comments).options.merge(reindex_on_touch: true))
    comment = Comment.create!(body: "seed", account_id: 1)

    got = writes { comment.touch }
    assert_equal 1, got["add"], "a touch indexes only the asking index (:comments), not :records: #{got.inspect}"

    got = writes do
      Comment.transaction do
        Comment.transaction(requires_new: true) { comment.touch; raise ActiveRecord::Rollback }
      end
    end
    assert_equal 0, got["add"], "a rolled-back touch must not index: #{got.inspect}"
  ensure
    Comment.send(:_index_reflections=, original)
  end
end
