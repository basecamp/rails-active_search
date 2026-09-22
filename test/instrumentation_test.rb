require "test_helper"

class InstrumentationTest < ActiveSupport::TestCase
  searches :articles

  setup do
    @article = Article.create!(title: "Instrumented", content: "Content", account_id: 1)
  end

  test "add emits add.active_search event" do
    events = collect_events("add.active_search") do
      ActiveSearch.index(:articles).add(@article)
    end

    assert_equal 1, events.size
    payload = events.first.payload
    assert_equal :articles, payload[:index]
    assert_equal @article.id.to_s, payload[:document_id]
    assert_equal :default, payload[:store_name]
  end

  test "remove_by_id emits remove.active_search event" do
    ActiveSearch.index(:articles).add(@article)
    id = ActiveSearch.index(:articles).id_for(@article)

    events = collect_events("remove.active_search") do
      ActiveSearch.index(:articles).remove_by_id(id)
    end

    assert_equal 1, events.size
    payload = events.first.payload
    assert_equal :articles, payload[:index]
    assert_equal id, payload[:document_id]
  end

  test "remove emits remove.active_search event" do
    ActiveSearch.index(:articles).add(@article)

    events = collect_events("remove.active_search") do
      ActiveSearch.index(:articles).remove(@article)
    end

    assert_equal 1, events.size
  end

  test "search results emits search.active_search event" do
    ActiveSearch.index(:articles).add(@article)

    results = nil
    events = collect_events("search.active_search") do
      results = ActiveSearch.index(:articles).search("Instrumented").results
    end

    assert_equal 1, events.size
    payload = events.first.payload
    assert_equal :articles, payload[:index]
    assert_equal :default, payload[:store_name]
    assert_equal "Instrumented".length, payload[:query_length]
    assert_equal 1, payload[:total]
    assert_equal false, payload[:partial_results]
    assert_equal results.total_exact?, payload[:total_relation] == :equal
  end

  test "the search payload carries no end-user query text" do
    secret = "Instrumented"
    events = collect_events("search.active_search") do
      ActiveSearch.index(:articles).search(secret).filter(status: "published").results
    end

    payload = events.first.payload

    assert_nil payload[:query]
    payload.each do |key, value|
      assert_not_includes value.to_s, secret, "#{key} carries the query text"
    end
  end

  test "the search payload reports the relation of an inexact total" do
    events = collect_events("search.active_search") do
      ActiveSearch.index(:articles).search("Instrumented").results
    end

    assert_includes ActiveSearch::Total::RELATIONS, events.first.payload[:total_relation]
  end

  test "search event includes total from results" do
    events = collect_events("search.active_search") do
      ActiveSearch.index(:articles).search("nonexistent").results
    end

    assert_equal 0, events.first.payload[:total]
  end

  test "batch flush emits flush_batch.active_search event" do
    articles = 3.times.map { |i| Article.create!(title: "Batch Inst #{i}", content: "C", account_id: 1) }

    events = collect_events("flush_batch.active_search") do
      ActiveSearch.index(:articles).batch do |batch|
        articles.each { |a| batch.add(a) }
      end
    end

    assert_equal 1, events.size
    payload = events.first.payload
    assert_equal :articles, payload[:index]
    assert_equal 3, payload[:operations]
  end

  test "empty batch flush does not emit event" do
    events = collect_events("flush_batch.active_search") do
      ActiveSearch.index(:articles).batch { |_batch| }
    end

    assert_empty events
  end

  test "all events include duration" do
    events = collect_events("add.active_search") do
      ActiveSearch.index(:articles).add(@article)
    end

    assert events.first.duration >= 0
  end

  STORE_METRICS = {
    elasticsearch: %i[took shards_failed timed_out terminated_early],
    opensearch: %i[took shards_failed timed_out terminated_early],
    solr: %i[took],
    typesense: %i[took],
    manticore: %i[took],
    meilisearch: %i[took]
  }.freeze

  test "the search payload carries what the store reports about serving the query" do
    events = collect_events("search.active_search") do
      ActiveSearch.index(:articles).search("Instrumented").results
    end
    metrics = events.first.payload[:store_metrics]
    expected = STORE_METRICS[store_adapter_name]

    if expected
      assert_equal expected.sort, metrics.keys.sort
      assert_kind_of Integer, metrics[:took]
    else
      assert_nil metrics, "#{store_adapter_name} reports nothing, so the key must be absent"
    end
  end

  DOCUMENTED_KEYS = {
    "search.active_search" => %i[index store_name query_length total total_relation partial_results],
    "add.active_search" => %i[index store_name document_id],
    "remove.active_search" => %i[index store_name document_id],
    "flush_batch.active_search" => %i[index store_name operations],
    "remove_by_filter.active_search" => %i[index store_name removed]
  }.freeze

  test "every event carries exactly the keys the README documents" do
    index = ActiveSearch.index(:articles)

    emitted = {}
    DOCUMENTED_KEYS.each_key do |name|
      collect_events(name) do
        index.add(@article)
        index.search("Instrumented").results
        index.batch { |batch| batch.add(@article) }
        index.remove(@article)
        index.remove_by_filter(account_id: @article.account_id)
      end.each { |event| emitted[name] = event.payload.keys.sort }
    end

    expected = DOCUMENTED_KEYS.transform_values(&:sort)
    if STORE_METRICS.key?(store_adapter_name)
      expected = expected.merge("search.active_search" => (DOCUMENTED_KEYS.fetch("search.active_search") + [ :store_metrics ]).sort)
    end

    assert_equal expected, emitted
  end

  private
    def collect_events(name)
      events = []
      callback = ->(*args) { events << ActiveSupport::Notifications::Event.new(*args) }
      ActiveSupport::Notifications.subscribed(callback, name) do
        yield
      end
      events
    end
end
