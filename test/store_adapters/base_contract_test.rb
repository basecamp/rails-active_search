require "test_helper"

# The hooks Base's own paths call on every adapter, checked against a subclass that implements
# only the documented abstract methods.
class BaseContractTest < ActiveSupport::TestCase
  class StubIndex
    def index_name
      :stub_docs
    end
  end

  # Answers searches from a script, records deletes.
  class ScriptedStore < ActiveSearch::StoreAdapters::Base
    attr_reader :deleted

    def initialize(pages:, **options)
      super(**options)
      @pages = pages
      @deleted = []
    end

    def search(index, query_context, routing: nil)
      @pages.shift || { total: 0, results: [], partial_results: false }
    end

    def delete(index, id, routing: nil)
      @deleted << id
    end
  end

  test "delete_by_filter aborts on a partial page before deleting anything" do
    store = ScriptedStore.new(pages: [
      { total: 2, results: [ { id: 1, fields: {} } ], partial_results: true }
    ])

    error = assert_raises(ActiveSearch::AdapterError) do
      store.send(:delete_by_filter, StubIndex.new, ActiveSearch::QueryContext.new)
    end

    assert_match(/partial/, error.message)
    assert_empty store.deleted, "ids from a page that hides matches were deleted anyway"
  end

  test "delete_by_filter pages a complete answer, refreshing between passes, and reports the count" do
    store = ScriptedStore.new(pages: [
      { total: 2, results: [ { id: 1, fields: {} }, { id: 2, fields: {} } ], partial_results: false },
      { total: 0, results: [], partial_results: false }
    ])

    assert_equal 2, store.send(:delete_by_filter, StubIndex.new, ActiveSearch::QueryContext.new)
    assert_equal [ 1, 2 ], store.deleted
  end

  # Named, because the contract errors put the adapter's name in their message.
  class BareStore < ActiveSearch::StoreAdapters::Base; end
  class BareDatabaseStore < ActiveSearch::StoreAdapters::Database; end

  test "apply_creation_plan without an implementation fails by contract, not NoMethodError" do
    assert_raises(NotImplementedError) { BareStore.new.apply_creation_plan(nil) }
  end

  test "a database adapter without observe_tables fails by contract, not NoMethodError" do
    assert_raises(NotImplementedError) { BareDatabaseStore.new.observe_tables(StubIndex.new, "stub_docs", nil) }
  end
end
