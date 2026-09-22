require "test_helper"

class MeilisearchTaskTest < ActiveSupport::TestCase
  setup do
    skip "Meilisearch-only behavior" unless store_adapter_name == :meilisearch

    @index = ActiveSearch.index(:creation_probes)
    @store = @index.store
    @store.drop_index(@index)
  end

  teardown do
    @store.drop_index(@index) if store_adapter_name == :meilisearch
  end

  test "flush raises when its task fails" do
    error = assert_raises(ActiveSearch::AdapterError) do
      @store.flush(@index, [ [ :add, [ document, nil ] ] ])
    end

    assert_match(/task \d+/, error.message)
    assert_match(/primary key/i, error.message)
  end

  test "refresh raises when a tracked write task failed" do
    @store.write(@index, document)

    assert_raises(ActiveSearch::AdapterError) { real_refresh }
  end

  test "flush and refresh stay quiet when tasks succeed" do
    @store.create_index(@index)
    @store.flush(@index, [ [ :add, [ document, nil ] ] ])
    @store.write(@index, document)

    assert_nothing_raised { real_refresh }
  end

  test "drop_index tolerates a missing index" do
    assert_nothing_raised { @store.drop_index(@index) }
  end

  test "a timed-out wait keeps the pending uids for the next refresh" do
    store = ActiveSearch::StoreAdapters::Meilisearch.new
    store.send(:track_task, :probe, 7)
    store.send(:track_task, :probe, 9)

    store.instance_variable_set(:@client, TimingOutClient.new)
    assert_raises(ActiveSearch::AdapterError) { adapter_refresh(store, :probe) }
    assert_equal [ 7, 9 ], store.instance_variable_get(:@pending_tasks)[:probe]

    store.instance_variable_set(:@client, SettlingClient.new)
    adapter_refresh(store, :probe)
    assert_equal [], store.instance_variable_get(:@pending_tasks)[:probe]
  end

  test "a failed task raises once rather than on every later refresh" do
    store = ActiveSearch::StoreAdapters::Meilisearch.new
    store.send(:track_task, :probe, 7)
    store.instance_variable_set(:@client, FailedTaskClient.new)

    assert_raises(ActiveSearch::AdapterError) { adapter_refresh(store, :probe) }
    assert_nothing_raised { adapter_refresh(store, :probe) }
  end

  test "a refresh overlapping another refresh keeps a write that lands between them" do
    store = ActiveSearch::StoreAdapters::Meilisearch.new
    store.send(:track_task, :probe, 7)
    store.instance_variable_set(:@client, OverlappingRefreshClient.new(store))

    store.send(:wait_for_pending_tasks, :probe)

    assert_equal [ 11 ], store.instance_variable_get(:@pending_tasks)[:probe]
  end

  test "a wait timeout during drop surfaces as AdapterError" do
    store = ActiveSearch::StoreAdapters::Meilisearch.new
    store.instance_variable_set(:@client, TimingOutClient.new)

    error = assert_raises(ActiveSearch::AdapterError) { store.drop_index(@index) }
    assert_match(/TimeoutError/, error.message)
  end

  class TimingOutClient
    def wait_for_task(*)
      raise ::Meilisearch::TimeoutError
    end

    def delete_index(*)
      { "taskUid" => 1 }
    end
  end

  class OverlappingRefreshClient
    def initialize(store)
      @store = store
      @overlapped = false
    end

    def wait_for_task(*)
      { "status" => "succeeded" }
    end

    def tasks(**)
      unless @overlapped
        @overlapped = true
        @store.send(:wait_for_pending_tasks, :probe)
        @store.send(:track_task, :probe, 11)
      end
      { "results" => [] }
    end
  end

  class SettlingClient
    def wait_for_task(*)
      { "status" => "succeeded" }
    end

    def tasks(**)
      { "results" => [] }
    end
  end

  class FailedTaskClient
    def wait_for_task(*)
      { "status" => "failed" }
    end

    def tasks(**)
      { "results" => [ { "uid" => 7, "status" => "failed", "type" => "documentAdditionOrUpdate",
                         "error" => { "code" => "invalid_document_id", "message" => "boom" } } ] }
    end
  end

  private
    def document
      ActiveSearch::Document.new(id: "probe-1", definition: @index.definition,
        data: { title: "task probe", account_id: 991 })
    end

    def real_refresh
      adapter_refresh(@store, @index.index_name)
    end

    def adapter_refresh(store, index_name)
      method = store.method(:refresh)
      method = method.super_method while method.owner == TestDeferredRefresh
      method.call(index_name)
    end
end
