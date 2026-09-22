module ActiveSearch
  # Represents a declared search index and starts immutable queries against it.
  #
  #   ActiveSearch.define_index(:articles) { text :title }
  #   ActiveSearch.index(:articles).search("query")
  #
  # Every Query method in the public API is also available on an Index. Calling one starts a new
  # Query, so an Index can be reused as the root of independent searches.
  class Index
    extend ActiveSupport::Autoload

    eager_autoload do
      autoload :Definition
      autoload :Field
      autoload :Querying
      autoload :Schema
    end

    include Querying

    # Returns the registry name, field definition, record source, configured store name, routing
    # field, and optional document class for this index.
    attr_reader :name, :definition, :source, :store_name, :route_by, :document_class

    # This name becomes Ruby, so classify must not fold two of them into one constant: a_b and a__b
    # both give AB, and the two declarations would share a document class.
    NAME_PATTERN = /\A[a-z][a-z0-9]*(?:_[a-z0-9]+)*\z/ # :nodoc:

    # The generator renders this as a class name, so it has to be one.
    CONSTANT_PATTERN = /\A[A-Z]\w*(?:::[A-Z]\w*)*\z/ # :nodoc:

    # The name sent to the store. Hyphens are allowed, so an index can be versioned (articles-v2);
    # consecutive underscores are not, because Manticore writes a hyphen as "__".
    STORE_NAME_PATTERN = /\A[a-z](?:[a-z0-9]|_(?!_))*(-[a-z](?:[a-z0-9]|_(?!_))*)*\z/ # :nodoc:

    # define_index calls this before deriving identity fields, so a bad index name reports itself
    # rather than surfacing as a bad derived field name.
    def self.validate_name!(option, value) # :nodoc:
      unless NAME_PATTERN.match?(value)
        raise ConfigurationError,
          "Invalid #{option} #{value.inspect}: use lowercase letters and digits separated by single " \
          "underscores, starting with a letter"
      end
    end

    def initialize(name, definition:, source: nil, store_name: nil, route_by: nil, index_name: nil, # :nodoc:
                   document_class: nil)
      @name = name.to_sym
      self.class.validate_name!("index name", @name)
      @index_name = index_name&.to_sym
      validate_store_name!(@index_name) if @index_name
      @definition = definition
      @source = source
      @store_name = store_name
      @route_by = route_by
      @document_class = document_class&.to_s&.dup&.freeze
      validate_document_class! if @document_class
    end

    # Names a Ruby class, so it takes the raw name -- never the store's prefix.
    def document_class_name # :nodoc:
      document_class || "#{(@index_name || name).to_s.tr("-", "/").classify}Document"
    end

    # Returns the name sent to the store, including its configured prefix.
    def index_name
      index_name_for(store)
    end

    # Takes a resolved store, so a caller cannot pair one store with another's prefix across a reload.
    def index_name_for(store) # :nodoc:
      prefix = store.index_prefix
      prefix.present? ? :"#{prefix}#{@index_name || name}" : (@index_name || name)
    end

    delegate :search_fields, :filter_fields, to: :definition

    # Returns the Capabilities declared by this index's store.
    #
    #   ActiveSearch.index(:articles).capabilities.supports_highlighting?
    def capabilities
      store.capabilities
    end

    # Returns the configured StoreAdapters::Base instance for this index.
    def store
      # Configuration owns the cache so a reload can replace an adapter instance.
      ActiveSearch.configuration.store_for(configured_store_name)
    end

    # -- Record-level operations (requires a source model) ------

    # Builds and returns the Document that +record+ would write without sending it to the store.
    #
    #   document = ActiveSearch.index(:articles).document_for(article)
    #
    # Raises ConfigurationError when the index has no record source or the record's class does not
    # declare +has_search+ for this index. Raises DocumentError when a field value is invalid.
    def document_for(record)
      require_source!
      ensure_record_indexable!(record)
      data = serialize_record(record)
      data.merge!(source.identity_attributes_for(record))

      Document.new(
        id: id_for(record),
        data: data,
        definition: definition
      )
    end

    # Returns the configured store name, using +:default+ when no name was declared.
    def configured_store_name
      store_name || :default
    end

    # Serializes +record+ and writes it to the store.
    #
    #   ActiveSearch.index(:articles).add(article)
    #
    # This direct operation does not apply +has_search+ guards. Raises ConfigurationError when the
    # index has no source or the record's class does not declare this index.
    def add(record)
      require_source!
      doc = document_for(record)
      ActiveSupport::Notifications.instrument("add.active_search", index: name, document_id: doc.id, store_name: configured_store_name) do
        store.add(self, doc, routing: routing_for(record))
      end
    end

    # Removes +record+'s document.
    #
    #   ActiveSearch.index(:articles).remove(article)
    #
    # The routing value is read from the record when the index declares +route_by:+.
    def remove(record)
      require_source!
      remove_by_id(id_for(record), routing: routing_for(record))
    end

    # Removes the document identified by +id+.
    #
    #   ActiveSearch.index(:articles).remove_by_id(article.id)
    #
    # ==== Options
    #
    # * +:routing+ - Supplies the routing value required by a routed index.
    def remove_by_id(id, routing: nil)
      ActiveSupport::Notifications.instrument("remove.active_search", index: name, document_id: id, store_name: configured_store_name) do
        store.remove(self, id, routing: routing)
      end
    end

    # Removes every document matching +conditions+ and returns the number removed.
    #
    #   ActiveSearch.index(:searchable).remove_by_filter(account_id: 1)
    #
    # Conditions use the same scalar, Array, Range, and nil forms as Query#filter. This method does
    # not add a model type filter, so a polymorphic index removes matching documents from every
    # model unless the conditions include its type field. Raises QueryError for blank or invalid
    # conditions and UnsupportedOperationError for a filter the store cannot perform.
    def remove_by_filter(conditions)
      raise QueryError, "remove_by_filter requires filter conditions" if conditions.blank?

      # Built through Query, so the filter gets the validation and casting a search would get.
      context = all.filter(conditions).send(:query_context_with_defaults)

      ActiveSupport::Notifications.instrument("remove_by_filter.active_search",
        index: name, store_name: configured_store_name) do |payload|
        payload[:removed] = store.remove_by_filter(self, context, routing: Routing.resolve(route_by, context))
      end
    end

    # Enqueues a ReindexJob for +record+ and returns the enqueued job.
    #
    # The job re-evaluates the index guards when it runs and may remove the document instead of
    # writing it. Raises ConfigurationError when the index has no record source.
    def reindex_later(record)
      require_source!
      ReindexJob.perform_later(name, record)
    end

    # Enqueues a RemoveJob for +record+ and returns the enqueued job.
    #
    # The record's identifier and routing value are captured before enqueueing. Raises
    # ConfigurationError when the index has no record source.
    def remove_later(record)
      require_source!
      RemoveJob.perform_later(name, id_for(record), routing: routing_for(record))
    end

    # Returns the source-defined identifier for +record+.
    def id_for(record)
      require_source!
      source.id_for(record)
    end

    # Returns the routing value for +record+, or nil when the index is not routed.
    #
    # A routing value must remain stable for the record's lifetime because a routed document is
    # identified by both its identifier and its route.
    def routing_for(record)
      route_by && record.public_send(route_by)
    end

    # Builds and returns a Batch that buffers adds and removals.
    #
    #   ActiveSearch.index(:articles).batch(max_size: 500) do |batch|
    #     Article.find_each { |article| batch.add(article) }
    #   end
    #
    # ==== Options
    #
    # * +:max_size+ - Flushes automatically at this many operations; defaults to 1,000. Pass nil to
    #   disable automatic flushing.
    # * Other options are forwarded to the adapter when the batch flushes.
    #
    # With a block, the batch flushes after the block returns. If the block raises, the closing
    # flush does not run.
    def batch(max_size: 1000, **options)
      batch = Batch.new(self, max_size: max_size, **options)
      if block_given?
        yield batch
        batch.flush
      end
      batch
    end

    private
      def validate_document_class!
        unless CONSTANT_PATTERN.match?(@document_class)
          raise ConfigurationError,
            "Invalid document_class #{@document_class.inspect}: give a constant path, as in Foo::BarDocument"
        end
      end

      def validate_store_name!(value)
        unless STORE_NAME_PATTERN.match?(value)
          raise ConfigurationError,
            "Invalid index_name #{value.inspect}: use lowercase letters, digits, single underscores " \
            "and hyphens, starting with a letter"
        end
      end

      def ensure_record_indexable!(record)
        return if record.class.respond_to?(:_index_reflections) &&
                  record.class._index_reflections[name]

        raise ConfigurationError, "#{record.class} must declare `has_search` to be indexed"
      end

      def serialize_record(record)
        record.class._index_reflections[name].serialize(record, definition)
      end

      def require_source!
        return if source
        raise ConfigurationError,
          "Index :#{name} has no record source. Specify a source: on define_index."
      end

    public

    ##
    # :method: all
    # :call-seq: all -> query
    #
    # Returns a new Query scoped to this index.
    #
    #   ActiveSearch.index(:articles).all
  end
end
