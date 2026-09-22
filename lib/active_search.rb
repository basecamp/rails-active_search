require "active_search/version"
require "active_search/engine"
require "active_search/errors"

##
# ActiveSearch adds full-text search to Rails applications through a common query API and a
# configurable store adapter. Index declarations live in +config/search.rb+, models opt in with
# Indexable#has_search, and searches return application records with Hit metadata.
#
#   ActiveSearch.define_index(:articles) do
#     text :title
#     string :status
#   end
#
#   Article.search("rails").filter(status: "published").results
module ActiveSearch
  extend ActiveSupport::Autoload

  eager_autoload do
    autoload :Configuration
  end

  autoload :Batch
  autoload :Capabilities
  autoload :Conditions
  require "active_search/log_subscriber"
  autoload :Document
  autoload :Highlighting
  autoload :Hit
  autoload :Index
  autoload :Indexable
  autoload :IndexReflection
  autoload :IndexingCallbacks
  autoload :Model
  autoload :Page
  autoload :QueryContext
  autoload :Query
  autoload :Routing
  autoload :Schema
  autoload :Resultable
  autoload :Results
  autoload :Score
  autoload :Total
  # Internal: callers ask for sort_by_relevance. A signpost rather than a boundary, since
  # private_constant leaves const_get and const_defined? working.
  private_constant :Score

  module Type # :nodoc: all
    extend ActiveSupport::Autoload

    autoload :Canonical
    autoload :String
    autoload :Integer
    autoload :Float
    autoload :Multiple
    autoload :Boolean
    autoload :Date
    autoload :DateTime
    autoload :BoundaryDateTime
    autoload :EpochMicrosecondsDateTime
    autoload :EpochSecondsDate
  end

  module Source # :nodoc: all
    extend ActiveSupport::Autoload

    autoload :Base
    autoload :Record
    autoload :Polymorphic
  end

  # Contains built-in adapters and the StoreAdapters::Base extension API.
  module StoreAdapters
    extend ActiveSupport::Autoload

    autoload :Base
    autoload :IndexLifecycle
    autoload :Database
    autoload :Elastic
    autoload :Elasticsearch
    autoload :Meilisearch
    autoload :Mysql
    autoload :Typesense
    autoload :Opensearch
    autoload :Solr
    autoload :RedisSearch
    autoload :Manticore
    autoload :Postgresql
    autoload :Sqlite
  end


  @configuration_lock = Mutex.new

  # :attr_reader: filter_attributes
  #
  # Returns the attribute names whose values are filtered when notification payloads are logged.
  mattr_reader :filter_attributes, default: []

  class << self
    # :attr_accessor: logger
    #
    # Gets or sets the logger used by ActiveSearch and supported backend clients.
    attr_accessor :logger

    # Sets the attribute names whose values are filtered when notification payloads are logged.
    #
    #   ActiveSearch.filter_attributes = [ :api_key, :password ]
    def filter_attributes=(filter_attributes)
      @parameter_filter = nil
      @@filter_attributes = filter_attributes
    end

    def parameter_filter # :nodoc:
      @parameter_filter ||= ActiveSupport::ParameterFilter.new(filter_attributes)
    end

    def configuration # :nodoc:
      @configuration || @configuration_lock.synchronize { @configuration ||= Configuration.new }
    end

    # Defines an index, registers it, and returns the new Index.
    #
    #   ActiveSearch.define_index(:articles) do
    #     text :title
    #     text :body
    #     string :status
    #     integer :tag_ids, multiple: true
    #   end
    #
    # ==== Options
    #
    # * +:polymorphic+ - Uses a polymorphic source. Pass +true+ to derive a singular role from the
    #   index name, or pass a Symbol to name the role.
    # * +:source+ - Uses the named model, or an object that responds to +records_for+ and +id_for+.
    #   The model is inferred from the index name when this option is omitted.
    # * +:route_by+ - Names the record method and filter field used for store routing.
    # * +:store_name+ - Selects a named store from +config/search.yml+; the default store is used
    #   when omitted.
    # * +:index_name+ - Replaces the name sent to the store while leaving the registry name intact.
    # * +:document_class+ - Names the Active Record document model used by database adapters.
    #
    # The block runs in an Index::Schema and declares fields with +text+, +string+, +integer+,
    # +float+, +boolean+, +date+, and +datetime+. The +source:+ and +polymorphic:+ options are
    # mutually exclusive. Raises ConfigurationError for an invalid or duplicate declaration,
    # missing field block, invalid source, or reserved field name.
    def define_index(name, polymorphic: false, source: nil, route_by: nil, **options, &block)
      # Symbolized before the source is built: has_search keys its reflections by symbol, and a
      # String would find none of them.
      name = name.to_sym
      raise ConfigurationError, "define_index requires a block with field definitions" unless block
      raise ConfigurationError, "define_index takes polymorphic: or source:, not both" if polymorphic && source
      Index.validate_name!("index name", name)

      fields = Index::Schema.from_block(block, index_name: name)
      resolved_source = build_source(name, source: source, polymorphic: polymorphic)
      definition = Index::Definition.new(fields: identity_fields(resolved_source, fields))
      idx = Index.new(name, definition: definition, source: resolved_source, route_by: route_by, **options)
      validate_reserved_field_names!(idx)
      configuration.register_index(name, idx)
      idx
    end

    # Returns the sorted names of all registered indexes.
    #
    #   ActiveSearch.index_names # => [ :articles, :products ]
    def index_names
      configuration.index_names
    end

    # Returns the registered Index for +name+.
    #
    #   ActiveSearch.index(:articles)
    #
    # Raises ConfigurationError when the index cannot be found or autoloaded.
    def index(name)
      configuration.index(name)
    end

    # Registers an adapter name with a class name.
    #
    #   ActiveSearch.register_adapter :my_sqlite, "My::SqliteAdapter"
    #
    # The class name must be a String or Symbol so the adapter and its client library can load on
    # first use. Registering the name again replaces its existing registration. Raises
    # ConfigurationError for an invalid adapter name or a class object.
    def register_adapter(name, class_name)
      configuration.register_adapter(name, class_name)
    end

    # Returns a store's configured options without constructing its adapter.
    #
    #   ActiveSearch.store_options(ActiveSearch.index(:articles).store_name)[:cluster]
    #
    # The returned Hash excludes +:adapter+ and may include credentials. With no argument, this
    # reads the default store. Raises ConfigurationError when a named store is not configured.
    def store_options(store_name = nil)
      configuration.store_options(store_name)
    end

    private
      # The source writes these into every document, so the declaration has to name them or a
      # filter on them raises. Only a scalar string: any other type mangles an id or a class name.
      def identity_fields(source, fields)
        names = source.respond_to?(:identity_fields) ? source.identity_fields : []

        names.reduce(fields) do |declared, name|
          existing = declared.find { |field| field.name == name }

          if existing.nil?
            declared + [ Index::Field.new(name, :string) ]
          elsif existing.type == :string && !existing.multiple?
            declared
          else
            raise ConfigurationError,
              "#{name} #{identity_reason(source, name)}, so it must be declared string, " \
              "not #{existing.multiple? ? "a collection of " : ""}#{existing.type}"
          end
        end
      end

      # Per store, not global: most stores keep their own id or score where a declared one would
      # collide, while Elasticsearch keeps _id apart from _source.id and can hold both.
      def validate_reserved_field_names!(index)
        adapter = configuration.store_adapter_class(index.configured_store_name)
        reserved = adapter ? index.definition.field_names & adapter.reserved_field_names : []

        if reserved.any?
          raise ConfigurationError,
            "Field name :#{reserved.first} is reserved on #{adapter.name.demodulize.underscore}: " \
            "the store keeps its own #{reserved.first} there, and a declared one would collide with it."
        end
      end

      # Why each has to be a scalar string: the id because the classes in one index need not share
      # an id type, the type column because it holds a class name.
      def identity_reason(source, name)
        if source.respond_to?(:type_column) && name == source.type_column
          "records which class a document came from"
        else
          "holds the record's id as text"
        end
      end

      # polymorphic: true derives a singular role from the index name, since Rails' _type/_id
      # columns are singular (belongs_to :searchable gives searchable_type). A symbol names the role.
      def polymorphic_role(polymorphic, index_name)
        if polymorphic == true
          role = index_name.to_s.singularize
          # A valid index name can still singularize to an invalid column (:audit_s -> "audit_"). An
          # invalid index name falls through to Index, which rejects it by name.
          if Index::NAME_PATTERN.match?(index_name) && !Index::NAME_PATTERN.match?(role)
            raise ConfigurationError,
              "polymorphic: true cannot derive a role from :#{index_name}: its singular #{role.inspect} " \
              "is not a valid column name. Name the role, as in polymorphic: :searchable."
          end
          role.to_sym
        elsif polymorphic.is_a?(Symbol) && Index::NAME_PATTERN.match?(polymorphic)
          polymorphic
        else
          raise ConfigurationError,
            "Invalid polymorphic role #{polymorphic.inspect}: give true, or a symbol naming the role"
        end
      end

      def build_source(index_name, source:, polymorphic:)
        if polymorphic
          Source::Polymorphic.new(name: polymorphic_role(polymorphic, index_name), index_name: index_name)
        elsif Source::Base::CUSTOM_CONTRACT.all? { |method| source.respond_to?(method) }
          source
        elsif source.is_a?(String)
          source_name = source.demodulize.underscore.to_sym
          Source::Record.new(name: source_name, index_name: index_name, source_class_name: source)
        elsif source.is_a?(Symbol)
          source_name = source.to_s.classify.demodulize.underscore.to_sym
          Source::Record.new(name: source_name, index_name: index_name, source_class_name: source.to_s.classify)
        elsif source.nil?
          class_name = index_name.to_s.classify
          source_name = class_name.demodulize.underscore.to_sym
          Source::Record.new(name: source_name, index_name: index_name, source_class_name: class_name)
        else
          raise ConfigurationError,
            "Invalid source #{source.inspect}. Use a class name, an object that responds to " \
            "records_for and id_for, or omit it to infer the class from the index name."
        end
      end
  end
end
