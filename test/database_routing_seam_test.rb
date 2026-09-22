require "test_helper"

class DatabaseRoutingSeamTest < ActiveSupport::TestCase
  SHARD_TABLES = { "a" => "routing_shard_a", "b" => "routing_shard_b" }.freeze

  setup do
    skip "database adapters only" unless store.is_a?(ActiveSearch::StoreAdapters::Database)

    @index = ActiveSearch.index(:creation_probes)
    @connection = ApplicationRecord.connection

    SHARD_TABLES.each_value { |table| build_shard_table(table) }

    @store = partitioned_store
    @store.shards = SHARD_TABLES.transform_values { |table| model_on(table) }
  end

  teardown { SHARD_TABLES.each_value { |table| drop_shard_table(table) } if @connection }

  test "a query built with routing reads the shard that routing names" do
    context = query_context_for(@index.filter(account_id: 1).limit(10))

    assert_match(/routing_shard_a/, build_raw_query("a", context).to_sql)
    assert_match(/routing_shard_b/, build_raw_query("b", context).to_sql)
    refute_match(/routing_shard_b/, build_raw_query("a", context).to_sql,
      "routing reached the query text but not the table, which is what it means here")
  end

  test "a write with routing puts the row in the shard that routing names" do
    @store.write(@index, document("1", title: "routed", status: "published", account_id: 1), routing: "b")

    assert_equal 0, @store.shards.fetch("a").count, "the unrouted shard took the row"
    assert_equal 1, @store.shards.fetch("b").count
    assert_equal "1", @store.shards.fetch("b").first.article_id
    assert_equal "routed", indexed_title_in(SHARD_TABLES.fetch("b")), "the text half missed the shard"
    assert_nil indexed_title_in(SHARD_TABLES.fetch("a"))
  end

  test "a delete with routing removes from the shard that routing names" do
    @store.shards.each_value { |model| model.create!(article_id: "1", account_id: 1) }

    @store.remove(@index, "1", routing: "b")

    assert_equal 1, @store.shards.fetch("a").count, "the unrouted shard kept its row"
    assert_equal 0, @store.shards.fetch("b").count
  end

  test "the index-wide facts answer without routing, which no document is in scope to supply" do
    assert_equal "routing_shard_a", @store.send(:document_table_name, @index)
    assert_equal @connection.adapter_name, @store.send(:document_connection, @index).adapter_name
    assert_nothing_raised { @store.send(:reset_column_information, @index) }
    assert_nothing_raised { @store.flush(@index, []) }
  end

  private
    def partitioned_store
      Class.new(store.class) do
        attr_accessor :shards

        private
          def model_for(index, routing: nil)
            shards.fetch(routing) { raise ActiveSearch::QueryError, "no shard for #{routing.inspect}" }
          end

          def connection_model_for(index)
            shards.fetch("a")
          end
      end.new
    end

    def build_shard_table(table)
      drop_shard_table(table)
      source = ActiveSearch::StoreAdapters::Database::MigrationSource.new(@index, table, store)
      Object.send(:remove_const, source.class_name) if Object.const_defined?(source.class_name)
      Object.class_eval(source.to_ruby) # rubocop:disable Security/Eval

      migration = Object.const_get(source.class_name).new
      migration.suppress_messages { migration.migrate(:up) }
    end

    def drop_shard_table(table)
      @connection.execute("DROP TABLE IF EXISTS #{table}_fts") if store_adapter_name == :sqlite
      @connection.drop_table table, if_exists: true
    end

    def indexed_title_in(table)
      from = store_adapter_name == :sqlite ? "#{table}_fts" : table
      @connection.select_value("SELECT title FROM #{from}")
    end

    def document(id, **data)
      ActiveSearch::Document.new(id: id, definition: @index.definition, data: data)
    end

    def build_raw_query(routing, context)
      @store.send(:build_raw_query, @index, context, routing: routing)
    end

    def model_on(table)
      Class.new(ApplicationRecord) do
        self.table_name = table
        define_singleton_method(:name) { table.camelize }
      end
    end
end
