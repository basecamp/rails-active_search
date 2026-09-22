require "test_helper"

class SchemaObservationTest < ActiveSupport::TestCase
  searches :articles

  class RecordingAdapter < ActiveSearch::StoreAdapters::Base
    attr_reader :written, :flushed, :observed

    def initialize(**options)
      super
      @written = []
      @flushed = []
      @observed = 0
    end

    def observe_index(index)
      @observed += 1
      [ :fact ]
    end

    private
      def write(index, document, routing: nil)
        @written << document
      end

      def flush(index, operations, **)
        @flushed.concat(operations)
      end

      def prepare_document(index, document, routing: nil)
        "prepared:#{document}"
      end
  end

  setup do
    @index = ActiveSearch.index(:articles)
    @adapter = RecordingAdapter.new
    @cache = ActiveSearch::Schema::ObservationCache.new
  end

  test "caches a successful observation" do
    calls = 0
    2.times { @cache.fetch(:k) { calls += 1; "value" } }

    assert_equal 1, calls
  end

  test "never caches a failure" do
    calls = 0
    2.times do
      assert_raises(RuntimeError) { @cache.fetch(:k) { calls += 1; raise "store down" } }
    end
    @cache.fetch(:k) { calls += 1; "recovered" }
    @cache.fetch(:k) { calls += 1; "unused" }

    assert_equal 3, calls
  end

  test "reset invalidates" do
    @cache.fetch(:k) { "old" }
    @cache.reset

    assert_equal "new", @cache.fetch(:k) { "new" }
  end

  test "a keyed reset invalidates only that key" do
    @cache.fetch(:a) { "a1" }
    @cache.fetch(:b) { "b1" }
    @cache.reset(:a)

    assert_equal "a2", @cache.fetch(:a) { "a2" }
    assert_equal "b1", @cache.fetch(:b) { "b1-unused" }
  end

  test "observed_schema caches per index and raises through" do
    2.times { @adapter.observed_schema(@index) }

    assert_equal 1, @adapter.observed
    @adapter.reset_schema_cache(@index)
    @adapter.observed_schema(@index)
    assert_equal 2, @adapter.observed
  end

  test "observed_schema keys by domain" do
    @adapter.observed_schema(@index, domain: :shard_0)
    @adapter.observed_schema(@index, domain: :shard_1)

    assert_equal 2, @adapter.observed
  end

  test "the cache is one instance from construction, so a reset is never lost to a second cache" do
    assert_same @adapter.send(:schema_observations), @adapter.send(:schema_observations)
  end

  test "drop_index resets the cache, so a later observation cannot serve the dropped schema" do
    dropping = Class.new(RecordingAdapter) do
      def perform_drop(index) = nil
    end.new

    dropping.observed_schema(@index)
    dropping.drop_index(@index)
    dropping.observed_schema(@index)

    assert_equal 2, dropping.observed
  end

  test "the database cache keys by table" do
    skip "database adapters only" unless store.is_a?(ActiveSearch::StoreAdapters::Database)
    articles = ActiveSearch.index(:articles)
    comments = ActiveSearch.index(:comments)

    assert_same articles.store, comments.store
    assert_includes articles.store.send(:schema_observation_key, articles, nil), "article_documents"
    refute_equal articles.store.send(:schema_observation_key, articles, nil),
      comments.store.send(:schema_observation_key, comments, nil)
  end

  test "a domain keys the cache and observes the table it names, without asking for a single one" do
    skip "database adapters only" unless store.is_a?(ActiveSearch::StoreAdapters::Database)
    conn = ApplicationRecord.connection
    conn.create_table "shard_probe", force: true do |t|
      t.string :shard_only_column
    end
    sharded = Class.new(ActiveSearch::StoreAdapters::Database) do
      def schema_domain(index, routing) = "shard_probe"
      def observe_for(index, domain)
        ApplicationRecord.connection.columns(domain).map { |c| ActiveSearch::Schema::Observation.new(name: c.name, role: :filterable) }
      end
      private
        def model_for(index, routing: nil) = raise ActiveSearch::QueryError, "No shard is in scope"
    end.new

    names = sharded.observed_schema(@index, domain: "shard_probe").map(&:name)
    assert_includes names, "shard_only_column", "the domain drove observation of the table it names"
  ensure
    conn&.drop_table "shard_probe", if_exists: true
  end

  test "add passes the document through prepare_document" do
    @adapter.add(@index, "doc")

    assert_equal [ "prepared:doc" ], @adapter.written
  end

  test "flush_batch prepares add operations and leaves removes alone" do
    @adapter.flush_batch(@index, [ [ :add, [ "doc", nil ] ], [ :remove, [ "id-1", nil ] ] ])

    assert_equal [ [ :add, [ "prepared:doc", nil ] ], [ :remove, [ "id-1", nil ] ] ], @adapter.flushed
  end

  test "observed_schema answers from the running store" do
    observations = store.observed_schema(@index)

    assert observations.any?, "expected at least one observation"
    assert_includes observations.map { |o| o.name.to_s }, "title"
    assert_same observations, store.observed_schema(@index)
  ensure
    store.reset_schema_cache(@index)
  end

  test "observed_schema raises for a missing table and does not cache the failure" do
    skip "database adapters only" unless store.is_a?(ActiveSearch::StoreAdapters::Database)
    missing = ActiveSearch.index(:creation_probes)

    2.times do
      assert_raises(ActiveRecord::StatementInvalid) { store.observed_schema(missing) }
    end
  end

  test "the cache holds until a reset, which then picks up a live column change" do
    skip "sqlite only" unless store_adapter_name == :sqlite
    probe = ActiveSearch.index(:creation_probes)
    conn = ApplicationRecord.connection

    begin
      conn.create_table "creation_probe_documents", force: true do |t|
        t.string :article_id, null: false
        t.integer :account_id
      end
      refute_includes observed(probe), "status"

      conn.add_column "creation_probe_documents", :status, :string
      refute_includes observed(probe), "status", "the cached observation must hold until a reset"

      probe.store.reset_schema_cache(probe)
      assert_includes observed(probe), "status"
    ensure
      conn.drop_table "creation_probe_documents", if_exists: true
      probe.store.reset_schema_cache(probe)
    end
  end

  private
    def observed(index)
      index.store.observed_schema(index).map { |o| o.name.to_s }
    end

  Obs = Struct.new(:name)

  class ShardedAdapter < ActiveSearch::StoreAdapters::Base
    attr_reader :observation_count

    def initialize
      super()
      @observation_count = 0
    end

    def perform_drop(index) = true

    private
      def observe_for(index, domain)
        @observation_count += 1
        [ Obs.new("title") ]
      end
  end

  test "drop_index clears per-domain schema observations" do
    adapter = ShardedAdapter.new
    index = ActiveSearch.index(:articles)

    adapter.observed_schema(index, domain: "shard_1")
    adapter.observed_schema(index, domain: "shard_1")
    assert_equal 1, adapter.observation_count,
      "the observation did not cache, so this test proves nothing"

    adapter.drop_index(index)

    adapter.observed_schema(index, domain: "shard_1")
    assert_equal 2, adapter.observation_count,
      "a routed write after drop_index still narrows against the dropped index's cached schema"
  end

  test "reset_schema_cache clears the sqlite column cache too" do
    skip "sqlite column cache; the sqlite run covers this" unless store_adapter_name == :sqlite

    adapter = ActiveSearch.index(:articles).store
    table = ArticleDocument.table_name
    adapter.send(:table_columns, ArticleDocument.connection, table, "#{table}_fts")
    assert adapter.instance_variable_get(:@table_columns_cache).present?, "cache did not warm"

    adapter.reset_schema_cache(ActiveSearch.index(:articles))

    assert adapter.instance_variable_get(:@table_columns_cache).blank?,
      "field selection keeps reading the dropped table's columns after the advertised reset"
  ensure
    ActiveSearch.index(:articles).store.instance_variable_set(:@table_columns_cache, nil)
  end
end
