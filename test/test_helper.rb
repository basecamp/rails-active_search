ENV["RAILS_ENV"] = "test"

# Ahead of the environment, so the lock covers the schema load in rails/test_help too.
require_relative "support/backend_lock"
BackendLock.acquire(ENV.fetch("SEARCH_ADAPTER", "sqlite"))

require_relative "../test/dummy/config/environment"

# A stand-in record for testing Index#add with arbitrary document data.
class TestRecord
  include GlobalID::Identification

  attr_reader :id

  def initialize(data)
    @data = data.transform_keys(&:to_sym)
    @id = @data[:id]
  end

  def method_missing(name, ...)
    @data.key?(name) ? @data[name] : super
  end

  def respond_to_missing?(name, include_private = false)
    @data.key?(name) || super
  end

  def self.find(id)
    raise "TestRecord.find not implemented"
  end
end
ActiveRecord::Migrator.migrations_paths = [ File.expand_path("../test/dummy/db/migrate", __dir__) ]
ActiveRecord::Migrator.migrations_paths << File.expand_path("../db/migrate", __dir__)
require "rails/test_help"

if ActiveSupport::TestCase.respond_to?(:fixture_paths=)
  ActiveSupport::TestCase.fixture_paths = [ File.expand_path("fixtures", __dir__) ]
  ActionDispatch::IntegrationTest.fixture_paths = ActiveSupport::TestCase.fixture_paths
  ActiveSupport::TestCase.file_fixture_path = File.expand_path("fixtures", __dir__) + "/files"
  ActiveSupport::TestCase.fixtures :all
end

# The client polls a task every 50ms by default and this suite waits on one per test. Test-only:
# the adapter passes no interval, so it takes this global.
Meilisearch::Models::Task.default_interval_ms = 1 if defined?(Meilisearch::Models::Task)

class ActiveSupport::TestCase
  # FTS tables need isolation, so one worker.
  parallelize(workers: 1)

  # after_commit callbacks only fire outside a transaction.
  self.use_transactional_tests = false

  # Which models each index's tests have to clear.
  SEARCH_INDEX_CONFIG = {
    articles: [ Article ],
    products: [ Product, Author ],
    comments: [ Comment ],
    records: [ Comment, Post, Page ],
    guarded_articles: [ GuardedArticle ],
    unless_guarded_articles: [ UnlessGuardedArticle ],
    proc_guarded_articles: [ ProcGuardedArticle ],
    namespaced_tests: [ Article ],
    topics: [ Topic ]
  }.freeze

  class_attribute :_search_indices, default: []

  def self.searches(*index_names)
    self._search_indices = index_names.map(&:to_sym)
  end

  setup do
    _search_indices.each do |index_name|
      setup_search_index(index_name)
      clean_models_for_index(index_name)
    end
  end

  teardown do
    _search_indices.each do |index_name|
      clean_models_for_index(index_name)
      teardown_search_index(index_name)
    end
  end

  # Asserts which records a query returns. Compares the hydrated page and the
  # backend total together, so a query cannot pass by returning the right rows
  # with the wrong total, or the reverse.
  #
  #   assert_results article, ActiveSearch.index(:articles).search("Content")
  #   assert_results [ article1, article2 ], relation
  #   assert_results [], relation
  def assert_results(expected, query, message = nil)
    expected_ids = Array(expected).map { |record| record.respond_to?(:id) ? record.id : record }
    results = query.results

    assert_equal expected_ids.sort, results.map(&:id).sort, message
    assert_equal expected_ids.size, results.total, message
  end

  # query_context is private. Tests read it through this one helper, so every place that reaches
  # past the public API is visible.
  def query_context_for(relation)
    relation.send(:query_context)
  end

  private
    def index_for(index_name)
      ActiveSearch.index(index_name)
    end

    def models_for_index(index_name)
      SEARCH_INDEX_CONFIG[index_name] || []
    end

    def clean_models_for_index(index_name)
      models_for_index(index_name).each(&:delete_all)
    end

    def setup_search_index(index_name)
      index_instance = index_for(index_name)
      return unless index_instance

      case store_adapter_name
      when :elasticsearch
        setup_elasticsearch_index(index_name, index_instance)
      when :opensearch
        setup_opensearch_index(index_name, index_instance)
      when :meilisearch
        setup_meilisearch_index(index_name, index_instance)
      when :solr
        setup_solr_core(index_name, index_instance)
      when :sqlite, :mysql, :postgresql
        clean_search_document_for(index_name)
      else
        rebuild_search_index(index_instance)
      end
    end

    # create_index refuses on a database adapter, so this drives the generator instead. Returns
    # the migration it wrote.
    def generate_document_for(index)
      require "generators/active_search/document/document_generator"
      generator = ActiveSearch::Generators::DocumentGenerator.new([ index.name.to_s ], [],
        destination_root: Rails.root)
      generator.shell.mute { generator.invoke_all }

      store = index.store
      waiting = store.send(:pending_migration_for, index, store.migration_source(index))
      Pathname.new(store.migration_directory(index)).join(waiting)
    end

    def rebuild_search_index(index_instance)
      index_instance.store.drop_index(index_instance) rescue nil
      index_instance.store.create_index(index_instance)
    end

    def teardown_search_index(index_name)
      index_instance = index_for(index_name)
      return unless index_instance

      case store_adapter_name
      when :solr
        teardown_solr_core(index_name, index_instance)
      when :redis_search, :manticore
        # These two cannot clear documents reliably, so setup rebuilds and teardown drops.
        index_instance.store.drop_index(index_instance) rescue nil
      end
    end

    def clean_search_document_for(index_name)
      # Match Database::DocumentClass.for: hyphens are namespace separators
      name = index_name.to_s.tr("-", "/")
      document_class = "#{name.classify}Document".safe_constantize

      # An index can be declared with no table behind it, and then there is nothing to clean.
      return unless document_class&.table_exists?

      # The FTS side table too: deleting only the meta rows leaves every FTS row orphaned.
      clean_fts_table_for(document_class) if store_adapter_name == :sqlite
      document_class.delete_all
    end

    # sqlite_master rather than table_exists?, which answers false for an FTS5 virtual table.
    def clean_fts_table_for(document_class)
      fts_table = "#{document_class.table_name}_fts"
      connection = document_class.connection
      return if connection.select_value("SELECT name FROM sqlite_master WHERE name = #{connection.quote(fts_table)}").nil?

      connection.execute("DELETE FROM #{fts_table}")
    end

    def store
      ActiveSearch.index(:articles).store
    end

    def store_adapter_name
      ENV.fetch("SEARCH_ADAPTER", "sqlite").to_sym
    end

    def capabilities
      store.capabilities
    end

    def supports_highlighting?
      capabilities.supports_highlighting?
    end

    def supports_snippet_unit?(unit)
      capabilities.supports_snippet_unit?(unit)
    end

    def supports_highlight_per_field_markers?
      capabilities.supports_highlight_per_field_markers?
    end

    def supports_highlight_per_field_snippets?
      capabilities.supports_highlight_per_field_snippets?
    end

    def supports_phrase_search?
      # All major adapters support phrase search via quoted strings
      true
    end

    def multi_value_filter_fields(index_instance)
      index_instance.definition.fields.select { |f| f.filterable? && f.multiple? }.map(&:name)
    end

    def filter_types_for(index_instance, mapping)
      index_instance.definition.fields
        .select(&:filterable?)
        .to_h { |field| [ field.name, mapping.fetch(field.type) ] }
    end

    ES_INDEX_SCHEMAS = {}

    # Routing is only observable across more than one shard: on a single-shard index every value
    # resolves to the same place, so a test asserting a union of shards passes whatever routing does.
    ROUTED_INDEX_SHARDS = 5

    def shards_for(index_instance)
      index_instance.route_by ? ROUTED_INDEX_SHARDS : 1
    end

    def setup_elasticsearch_index(index_name, index_instance)
      client = index_instance.store.client
      properties = index_instance.store.creation_plan(index_instance).native[:mappings][:properties]

      shards = shards_for(index_instance)
      schema_signature = [ properties, shards ].hash

      if ES_INDEX_SCHEMAS[index_name] == schema_signature
        client.delete_by_query(index: index_name.to_s, body: { query: { match_all: {} } }, refresh: true)
        return
      end

      not_found_error = ActiveSearch::StoreAdapters::Elasticsearch.not_found_error
      begin
        client.indices.delete(index: index_name.to_s)
      rescue not_found_error
      end

      client.indices.create(index: index_name.to_s,
        body: { settings: { number_of_shards: shards }, mappings: { properties: properties } })
      ES_INDEX_SCHEMAS[index_name] = schema_signature
    end

    OPENSEARCH_INDEX_SCHEMAS = {}

    def setup_opensearch_index(index_name, index_instance)
      client = index_instance.store.client
      properties = index_instance.store.creation_plan(index_instance).native[:mappings][:properties]
      shards = shards_for(index_instance)
      schema_signature = [ properties, shards ].hash

      if OPENSEARCH_INDEX_SCHEMAS[index_name] == schema_signature
        client.delete_by_query(index: index_name.to_s, body: { query: { match_all: {} } }, refresh: true)
        return
      end

      begin
        client.indices.delete(index: index_name.to_s)
      rescue OpenSearch::Transport::Transport::Errors::NotFound
      end

      client.indices.create(index: index_name.to_s,
        body: { settings: { number_of_shards: shards }, mappings: { properties: properties } })
      OPENSEARCH_INDEX_SCHEMAS[index_name] = schema_signature
    end

    MEILISEARCH_INDEX_SCHEMAS = {}

    def setup_meilisearch_index(index_name, index_instance)
      store = index_instance.store
      signature = store.creation_plan(index_instance).native.hash

      # Handed to the adapter's pending list rather than waited on, so the clear shares a task
      # batch with the writes that follow it.
      if MEILISEARCH_INDEX_SCHEMAS[index_name] == signature
        TestDeferredRefresh.clear_later(store, index_name)
        return
      end

      # The delete is a task, so creating before it lands finds the index still there.
      store.drop_index(index_instance) rescue nil
      store.create_index(index_instance)
      MEILISEARCH_INDEX_SCHEMAS[index_name] = signature
    end

    SOLR_FIELD_TYPES = {
      integer: "plong",
      float: "pfloat",
      string: "string",
      datetime: "pdate",
      date: "pdate",
      boolean: "boolean"
    }.freeze

    SOLR_CORE_SCHEMAS = {}

    def setup_solr_core(core_name, index_instance)
      client = index_instance.store.client(core_name)

      # Cores are pre-created in docker-compose.yml, so only the documents go. Soft, because the
      # next test needs the deletion visible rather than durable.
      client.delete_by_query("*:*")
      client.soft_commit

      # Reading the schema costs two HTTP calls, and it cannot change within a run.
      signature = [ index_instance.search_fields, filter_types_for(index_instance, SOLR_FIELD_TYPES) ].hash
      return if SOLR_CORE_SCHEMAS[core_name] == signature

      setup_solr_schema(client, index_instance)
      SOLR_CORE_SCHEMAS[core_name] = signature
    end

    def setup_solr_schema(client, index_instance)
      require "net/http"
      require "json"

      base_url = client.uri.to_s.gsub(/\/[^\/]*$/, "")
      schema_url = URI("#{base_url}/schema")

      existing_field_types_by_name = get_solr_field_types_by_name(schema_url)
      existing_fields = existing_field_types_by_name.keys
      existing_field_types = get_solr_field_types(schema_url)

      http = Net::HTTP.new(schema_url.host, schema_url.port)

      fields_to_add = {}

      index_instance.search_fields.each do |field|
        field_name = field.to_s
        unless existing_fields.include?(field_name) || fields_to_add.key?(field_name)
          fields_to_add[field_name] = { name: field_name, type: "text_general", stored: true, indexed: true, multiValued: false }
        end
      end

      # Solr will not retype an existing field, so one whose declared type changed is replaced.
      fields_to_replace = {}

      many = multi_value_filter_fields(index_instance)

      filter_types_for(index_instance, SOLR_FIELD_TYPES).each do |field, native|
        field_name = field.to_s
        solr_type = native || "string"
        definition = { name: field_name, type: solr_type, stored: true, indexed: true,
                       multiValued: many.include?(field) }

        if !existing_fields.include?(field_name)
          fields_to_add[field_name] = definition unless fields_to_add.key?(field_name)
        elsif existing_field_types_by_name[field_name] != solr_type
          fields_to_replace[field_name] = definition
        end
      end

      apply_solr_schema_changes(http, schema_url, "replace-field", fields_to_replace)

      return if fields_to_add.empty?

      # Add fields one by one to avoid batch failure when one field already exists
      fields_to_add.each_value do |field_def|
        request = Net::HTTP::Post.new(schema_url)
        request["Content-Type"] = "application/json"
        request.body = { "add-field" => field_def }.to_json
        response = http.request(request)
        unless response.is_a?(Net::HTTPSuccess)
          unless response.body.include?("already exists")
            puts "Solr Schema API error adding field '#{field_def[:name]}' (#{response.code}): #{response.body}"
          end
        end
      end
    rescue => e
      puts "Solr Schema API exception: #{e.class} - #{e.message}"
    end

    def apply_solr_schema_changes(http, schema_url, action, definitions)
      require "net/http"
      require "json"

      definitions.each_value do |field_def|
        request = Net::HTTP::Post.new(schema_url)
        request["Content-Type"] = "application/json"
        request.body = { action => field_def }.to_json
        response = http.request(request)

        unless response.is_a?(Net::HTTPSuccess)
          puts "Solr Schema API error on #{action} for '#{field_def[:name]}' (#{response.code}): #{response.body}"
        end
      end
    end

    def get_solr_field_types_by_name(schema_url)
      require "net/http"
      require "json"

      fields_url = URI("#{schema_url}/fields")
      data = JSON.parse(Net::HTTP.get(fields_url))
      data["fields"].to_h { |f| [ f["name"], f["type"] ] }
    rescue
      {}
    end

    def get_solr_fields(schema_url)
      require "net/http"
      require "json"

      fields_url = URI("#{schema_url}/fields")
      response = Net::HTTP.get(fields_url)
      data = JSON.parse(response)
      data["fields"].map { |f| f["name"] }
    rescue
      []
    end

    def get_solr_field_types(schema_url)
      require "net/http"
      require "json"

      types_url = URI("#{schema_url}/fieldtypes")
      response = Net::HTTP.get(types_url)
      data = JSON.parse(response)
      data["fieldTypes"].map { |f| f["name"] }
    rescue
      []
    end

    def teardown_solr_core(core_name, index_instance)
      client = index_instance.store.client(core_name)
      client.delete_by_query("*:*")
      client.commit
    rescue RSolr::Error::Http
      # Core might not exist
    end

    def drop_manticore_table(http, table_name)
      manticore_table = table_name.to_s.gsub("-", "__")
      manticore_sql(http, "DROP TABLE IF EXISTS #{manticore_table}")
    end

    def manticore_sql(http, query)
      require "net/http"
      require "json"

      req = Net::HTTP::Post.new("/sql?mode=raw")
      req["Content-Type"] = "application/x-www-form-urlencoded"
      req.body = "query=#{URI.encode_www_form_component(query)}"
      http.request(req)
    end

    def refresh_search_index
      if store_adapter_name == :elasticsearch
        store.refresh(:articles)
      end
    end
end

# Refreshes after every mutation, for a store that needs an explicit one.
module TestAutoRefresh
  def add(index, document, **)
    super.tap { refresh(index.index_name) }
  end

  def remove(index, id, **)
    super.tap { refresh(index.index_name) }
  end
end

# The same, deferred until something reads, because Meilisearch charges a fixed cost per task
# batch. Elasticsearch and OpenSearch cannot use it: they delete by query on the server, which
# reads the index without going through #search and so acts on a stale view.
module TestDeferredRefresh
  # Keyed by store as well as index name, so two stores sharing an index name do not collapse into
  # one pending clear and leave the second holding stale documents.
  def self.clear_later(store, index_name) = pending_clears << [ store, index_name ]
  def self.pending_clears = @pending_clears ||= Set.new

  def add(index, document, **)
    flush_clear(index)
    super.tap { pending_refreshes << index.index_name }
  end

  def remove(index, id, **)
    flush_clear(index)
    super.tap { pending_refreshes << index.index_name }
  end

  # A bulk write is a write: without this the clear fires at read time and empties what was written.
  def flush_batch(index, operations, **)
    flush_clear(index)
    super
  end

  # An explicit refresh only marks the index; the read is the only place the answer must be right.
  def refresh(index_name)
    pending_refreshes << index_name
  end

  def search(index, query_context, **)
    flush_clear(index)
    refresh_pending(index.index_name)
    super
  end

  def remove_by_filter(index, query_context, **)
    flush_clear(index)
    refresh_pending(index.index_name)
    super
  end

  private
    def flush_clear(index)
      return unless TestDeferredRefresh.pending_clears.delete?([ self, index.index_name ])

      task = @client.index(index.index_name.to_s).delete_all_documents
      track_task(index.index_name, task["taskUid"])
      pending_refreshes << index.index_name
    end

    def refresh_pending(index_name)
      method(:refresh).super_method.call(index_name) if pending_refreshes.delete?(index_name)
    end

    def pending_refreshes
      @pending_refreshes ||= Set.new
    end
end

case ENV["SEARCH_ADAPTER"]
when "elasticsearch"
  ActiveSearch::StoreAdapters::Elasticsearch.prepend(TestAutoRefresh)
when "opensearch"
  ActiveSearch::StoreAdapters::Opensearch.prepend(TestAutoRefresh)
when "meilisearch"
  ActiveSearch::StoreAdapters::Meilisearch.prepend(TestDeferredRefresh)
end
