require "test_helper"

class WriteIntersectionTest < ActiveSupport::TestCase
  Obs = Struct.new(:name)

  def definition
    ActiveSearch.index(:articles).definition
  end

  def document(data)
    ActiveSearch::Document.new(id: "1", definition: definition, data: data)
  end

  test "narrow_to drops fields the store does not hold, from data and the writable set" do
    doc = document(title: "hi", status: "published", account_id: 7)
    narrowed = doc.narrow_to(%w[ title account_id ])

    assert_equal %i[ title account_id ], narrowed.writable_field_names & %i[ title status account_id ]
    refute_includes narrowed.writable_field_names, :status
    refute_includes narrowed.data.keys, :status
    assert_equal "hi", narrowed.data[:title]
  end

  test "writable_field_names is every declared field until narrowed" do
    assert_equal definition.field_names, document(title: "hi").writable_field_names
  end

  test "search_fields and filter_field_names follow the writable set" do
    doc = document(title: "hi", status: "published", account_id: 7).narrow_to(%w[ title account_id ])

    assert_equal [ :title ], doc.search_fields
    assert_equal [ :account_id ], doc.filter_field_names
  end

  class NarrowingAdapter < ActiveSearch::StoreAdapters::Base
    attr_reader :written
    def initialize(observed:)
      super()
      @observed = observed
      @written = nil
    end
    def observe_index(index) = @observed.map { |n| Obs.new(n) }
    private
      def write(index, document, routing: nil) = @written = document
  end

  class ShardedAdapter < ActiveSearch::StoreAdapters::Base
    attr_reader :written
    SHARDS = { 0 => %w[ title ], 1 => %w[ title status ] }.freeze
    private
      def write(index, document, routing: nil) = @written = document
      def schema_domain(index, routing) = routing.to_i % 2
      def observe_for(index, domain) = SHARDS.fetch(domain).map { |n| Obs.new(n) }
  end

  test "add narrows the document to the observed field names" do
    adapter = NarrowingAdapter.new(observed: %w[ title account_id ])
    adapter.add(ActiveSearch.index(:articles), document(title: "hi", status: "x", account_id: 7))

    assert_equal %i[ account_id title ], adapter.written.data.keys.sort
    refute_includes adapter.written.data.keys, :status
  end

  test "routing selects the shard whose observed schema narrows the write" do
    adapter = ShardedAdapter.new
    index = ActiveSearch.index(:articles)

    adapter.add(index, document(title: "hi", status: "published"), routing: 0)
    assert_equal %i[ title ], adapter.written.data.keys, "shard 0 lacks status, so it is dropped"

    adapter.add(index, document(title: "hi", status: "published"), routing: 1)
    assert_equal %i[ status title ], adapter.written.data.keys.sort, "shard 1 has status"
  end

  TABLE = "creation_probe_documents"

  def sqlite? = store_adapter_name == :sqlite

  def build_scratch_table(with_status:, with_fts: true)
    conn = ApplicationRecord.connection
    drop_scratch_table
    conn.create_table TABLE, force: true do |t|
      t.string :article_id, null: false
      t.integer :account_id
      t.string :status if with_status
    end
    conn.add_index TABLE, :article_id, unique: true
    conn.execute("CREATE VIRTUAL TABLE #{TABLE}_fts USING fts5(title)") if with_fts
    store.reset_schema_cache(index)
  end

  def drop_scratch_table
    conn = ApplicationRecord.connection
    conn.execute("DROP TABLE IF EXISTS #{TABLE}_fts")
    conn.drop_table TABLE, if_exists: true
    store.reset_schema_cache(index) if sqlite?
  end

  def index = ActiveSearch.index(:creation_probes)
  def store = index.store

  def probe_document(status:)
    ActiveSearch::Document.new(id: "art-1", definition: index.definition,
      data: { title: "scratch probe", status: status, account_id: 42 })
  end

  def written_row
    ApplicationRecord.connection.select_one("SELECT * FROM #{TABLE} WHERE article_id = 'art-1'")
  end

  teardown { drop_scratch_table if sqlite? }

  test "the write omits a column the table lacks, and carries it once the column exists" do
    skip "sqlite drives the real-store leg" unless sqlite?

    build_scratch_table(with_status: false)
    store.add(index, probe_document(status: "published"))
    row = written_row

    assert_equal "scratch probe", ApplicationRecord.connection.select_value(
      "SELECT title FROM #{TABLE}_fts")
    assert_equal 42, row["account_id"]
    refute row.key?("status"), "status is not a column, so it must not have been written"

    build_scratch_table(with_status: true)
    store.add(index, probe_document(status: "published"))

    assert_equal "published", written_row["status"]
  end

  test "a stale cache is what the reset guards: without the reset the new column is not written" do
    skip "sqlite drives the real-store leg" unless sqlite?

    build_scratch_table(with_status: false)
    store.observed_schema(index) # warm the cache against the narrow table

    ApplicationRecord.connection.add_column TABLE, :status, :string
    store.add(index, probe_document(status: "published"))

    assert_nil written_row["status"], "cached observation still lacks status, so the write omits it"

    store.reset_schema_cache(index)
    store.add(index, probe_document(status: "published"))
    assert_equal "published", written_row["status"]
  end

  test "a write with every searchable field narrowed away refuses instead of half-writing" do
    skip "sqlite drives the real-store leg" unless sqlite?

    build_scratch_table(with_status: false, with_fts: false)

    error = assert_raises(ActiveSearch::UnsearchableWriteError) do
      store.add(index, probe_document(status: "published"))
    end
    assert_match(/title/, error.message)
    assert_nil written_row, "a refused write must leave nothing behind"
  end

  test "narrowing away every searchable field refuses the write at the seam" do
    adapter = NarrowingAdapter.new(observed: %w[ status account_id ])

    error = assert_raises(ActiveSearch::UnsearchableWriteError) do
      adapter.add(ActiveSearch.index(:articles), document(title: "hi", status: "x", account_id: 7))
    end
    assert_match(/articles/, error.message)
    assert_nil adapter.written
  end

  test "a filter-only definition writes without a searchable field" do
    fields = ActiveSearch::Index::Schema.from_block(proc {
      string :status
      integer :account_id
    })
    filter_only = ActiveSearch::Index::Definition.new(fields: fields)
    fake_index = Struct.new(:index_name, :definition).new("filter_only_probe", filter_only)
    adapter = NarrowingAdapter.new(observed: %w[ status account_id ])

    adapter.add(fake_index, ActiveSearch::Document.new(id: "1", definition: filter_only, data: { status: "x" }))

    assert_equal [ :status ], adapter.written.data.keys
  end
end
