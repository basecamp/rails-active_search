require "test_helper"

class IntentLifecycleTest < ActiveSupport::TestCase
  searches :guarded_articles

  test "an inner savepoint rollback does not cancel the outer transaction's write" do
    ga = GuardedArticle.create!(title: "start", content: "text", should_index: true)

    ActiveRecord::Base.transaction do
      ga.update!(title: "outer wins")

      ActiveRecord::Base.transaction(requires_new: true) do
        ga.update!(title: "inner loses")
        raise ActiveRecord::Rollback
      end
    end

    assert_equal "outer wins", ga.reload.title

    assert_results [ ga ], index.search("outer"),
      "the savepoint rollback cleared the outer save's intent, so the commit indexed nothing"
  end

  test "a failed synchronous write does not leave an intent for a later touch to fire" do
    ga = GuardedArticle.create!(title: "sync start", content: "text", should_index: true)

    assert_raises(ActiveSearch::AdapterError) do
      with_failing_add { ga.update!(title: "failed write") }
    end

    GuardedArticle.suppress_indexing { ga.touch }

    assert_results [], index.search("failed"),
      "the stale intent from the failed write fired on a bare touch, through suppression"
  end

  private
    def index
      ActiveSearch.index(:guarded_articles)
    end

    def with_failing_add
      index.define_singleton_method(:add) { |_record| raise ActiveSearch::AdapterError, "store down" }
      yield
    ensure
      index.singleton_class.remove_method(:add)
    end
end
