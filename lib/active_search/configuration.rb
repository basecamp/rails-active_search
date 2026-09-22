require "concurrent/map"
require "monitor"

module ActiveSearch
  class Configuration # :nodoc:
    include MonitorMixin

    def initialize
      super # MonitorMixin
      @store_configs = {}
      @stores = Concurrent::Map.new
      @indexes = Concurrent::Map.new
      @reloaded_index_names = Set.new
      @reloading = false
      @adapters = {}
      register_built_in_adapters
    end

    # -- Index registry --------------------------------------------------------

    def register_index(name, index) # :nodoc:
      synchronize do
        key = name.to_sym

        # Re-registering across reloads is how a reload works; twice within one pass is a duplicate.
        if @reloading && @reloaded_index_names.include?(key)
          raise ConfigurationError,
            "Index :#{key} is defined twice in config/search.rb. Remove one definition."
        end

        @indexes[key] = index
        @reloaded_index_names << key if @reloading
      end
    end

    def unregister_index(name)
      synchronize { @indexes.delete(name.to_sym) }
    end

    # Runs the block that loads config/search.rb, having dropped the indexes the last one defined.
    # Indexes registered outside this block — by an engine, at boot — are not reloadable and stay.
    def reloading_indexes # :nodoc:
      synchronize do
        @reloaded_index_names.each { |name| @indexes.delete(name) }
        @reloaded_index_names = Set.new
        @reloading = true
      end

      yield
    ensure
      synchronize { @reloading = false }
    end

    # An index that is already registered is read without taking the monitor.
    def index(name)
      key = name.to_sym
      @indexes[key] || resolve_index(key)
    end

    # Every index declared so far, sorted.
    def index_names
      @indexes.keys.sort
    end

    # -- Store resolution ------------------------------------------------------

    def store_names
      named_stores? ? @store_configs.keys : [ :default ]
    end

    # Cached per name, and kept across a reload unless the adapter class itself was replaced — see
    # discard_replaced_stores.
    def store_for(store_name = nil) # :nodoc:
      name = store_name || :default
      @stores.compute_if_absent(name) { build_store(name) }
    end

    # An adapter defined in application code is reloadable, so a cached store can be an instance of
    # a class the reloader replaced. Drops only those; the rest keep their connections.
    def discard_replaced_stores # :nodoc:
      synchronize do
        @stores.keys.each { |name| @stores.delete(name) unless store_class_current?(name) }
      end
    end

    # -- Adapter registry ------------------------------------------------------

    # A plain identifier, so the install generator can write it into search.yml unquoted, the way
    # database.yml names an adapter.
    ADAPTER_NAME_PATTERN = /\A[a-z][a-z0-9_]*\z/

    # Mirrors ActiveRecord::ConnectionAdapters.register. A name already registered is replaced,
    # which is how an adapter is aliased.
    def register_adapter(name, class_name) # :nodoc:
      unless class_name.is_a?(String) || class_name.is_a?(Symbol)
        raise ConfigurationError,
          "Adapter :#{name} must be registered with a class name rather than #{class_name.class}. " \
          "A name is what defers loading the adapter and its client library until it is used."
      end

      unless ADAPTER_NAME_PATTERN.match?(name.to_s)
        raise ConfigurationError,
          "Invalid adapter name #{name.inspect}: use lowercase letters, digits and underscores, " \
          "starting with a letter."
      end

      @adapters[name.to_sym] = class_name.to_s
    end

    def adapter_class_for(name) # :nodoc:
      key = name.to_sym
      class_name = @adapters[key] || raise(ConfigurationError, unregistered_adapter_message(key))

      resolve_adapter(key, class_name)
    end

    # The options a store is configured with, as written in config/search.yml minus the adapter
    # name and including any credentials. Reads the configuration without building the store,
    # whose constructor may contact the backend.
    #
    #   ActiveSearch.store_options(:default)[:cluster]
    def store_options(store_name = nil) # :nodoc:
      store_config(store_name || :default).except(:adapter)
    end

    def registered_adapter_names # :nodoc:
      @adapters.keys.sort
    end

    # The adapter class serving a store, without building the store. Nil when the store or its
    # adapter does not resolve, so that failure is raised at first use.
    def store_adapter_class(store_name = nil) # :nodoc:
      adapter_class_for(store_config(store_name || :default)[:adapter])
    rescue ConfigurationError
      nil
    end

    def apply_store_config(config) # :nodoc:
      synchronize do
        @store_configs = config
        @stores = Concurrent::Map.new
      end
    end

    private
      # The autoload runs outside the lock, so racing threads may each pay for it.
      def resolve_index(key)
        synchronize { return @indexes[key] if @indexes[key] }
        autoload_index(key)
      end

      # Covers a job worker that has not eager-loaded models.
      def autoload_index(key)
        class_name = key.to_s.classify
        begin
          class_name.constantize
        rescue NameError => e
          # A NameError raised inside the class body names some other constant, so it goes through.
          expected_names = class_name.split("::")
          raise unless expected_names.include?(e.name.to_s)

          raise ConfigurationError, "#{undefined_index_message(key)} #{class_name} did not autoload: #{e.message}."
        end

        # Loading the class may itself have registered the index.
        synchronize { @indexes[key] || raise(ConfigurationError, undefined_index_message(key)) }
      end

      # A configuration that no longer resolves counts as stale, so the error is raised at use
      # rather than breaking the reload.
      def store_class_current?(name)
        @stores[name].instance_of?(adapter_class_for(store_config(name)[:adapter]))
      rescue ConfigurationError
        false
      end

      def build_store(store_name)
        config = store_config(store_name)
        adapter_class_for(config[:adapter]).new(**config.except(:adapter))
      end

      def register_built_in_adapters
        register_adapter :elasticsearch, "ActiveSearch::StoreAdapters::Elasticsearch"
        register_adapter :opensearch, "ActiveSearch::StoreAdapters::Opensearch"
        register_adapter :solr, "ActiveSearch::StoreAdapters::Solr"
        register_adapter :meilisearch, "ActiveSearch::StoreAdapters::Meilisearch"
        register_adapter :typesense, "ActiveSearch::StoreAdapters::Typesense"
        register_adapter :redis_search, "ActiveSearch::StoreAdapters::RedisSearch"
        register_adapter :manticore, "ActiveSearch::StoreAdapters::Manticore"
        register_adapter :postgresql, "ActiveSearch::StoreAdapters::Postgresql"
        register_adapter :mysql, "ActiveSearch::StoreAdapters::Mysql"
        register_adapter :sqlite, "ActiveSearch::StoreAdapters::Sqlite"
      end

      # An adapter file requires its client library, so a missing gem raises LoadError, which is
      # not a StandardError and needs its own rescue.
      def resolve_adapter(key, class_name)
        klass = class_name.constantize

        unless klass.is_a?(Class) && klass < StoreAdapters::Base
          raise ConfigurationError,
            "Adapter :#{key} names #{class_name}, which does not inherit from " \
            "ActiveSearch::StoreAdapters::Base"
        end

        klass
      rescue LoadError => e
        raise ConfigurationError,
          "Adapter :#{key} could not load its client library: #{e.message}. Add it to your Gemfile."
      rescue NameError => e
        raise ConfigurationError, "Adapter :#{key} names #{class_name}, which does not exist: #{e.message}"
      end

      def undefined_index_message(key)
        "Unknown index :#{key}. Define it with ActiveSearch.define_index in config/search.rb."
      end

      def unregistered_adapter_message(key)
        "Unknown adapter :#{key}. Registered adapters are #{registered_adapter_names.join(", ")}. " \
        "Register another with ActiveSearch.register_adapter(:#{key}, \"Your::AdapterClass\")."
      end

      # No fallback to :default: an index naming a store that does not exist has to raise rather
      # than search somewhere plausible.
      def store_config(name)
        if named_stores?
          entry = @store_configs[name] ||
            raise(ConfigurationError, "Unknown store :#{name}. Configured stores are #{@store_configs.keys.join(", ")}.")

          entry.is_a?(Hash) ? entry :
            raise(ConfigurationError, "Store :#{name} must be configured with a Hash, got #{entry.class}")
        elsif name == :default
          @store_configs
        else
          raise ConfigurationError,
            "Unknown store :#{name}. config/search.yml names a single store, which is :default."
        end
      end

      def named_stores?
        # A top-level :adapter key means a single store; anything else is named stores.
        !@store_configs.key?(:adapter)
      end
  end
end
