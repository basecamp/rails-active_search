module ActiveSearch
  module StoreAdapters
    # Defines the extension contract for a search store adapter.
    #
    # A subclass implements the private methods #write, #delete, #flush, #build_raw_query, and
    # #execute_query, and implements the public methods #ping and #capabilities. Base supplies the
    # public write and search operations, validates the store's page limit, prepares documents,
    # projects hit fields, and translates exception classes listed in +CLIENT_ERRORS+ to AdapterError.
    #
    # An adapter whose store has a schema also implements +observe_index+, which reports the fields
    # the store holds for an index; Base calls it before every write to prepare the document, and
    # raises NotImplementedError without it. A schemaless adapter overrides +prepare_document+
    # instead. Adapters may override #refresh and #type_casters when their backend requires them.
    class Base
      include IndexLifecycle

      # Lists backend exception classes that Base converts to AdapterError.
      CLIENT_ERRORS = [].freeze

      # A prefix that composes with a valid index name into a still-valid store name.
      INDEX_PREFIX_PATTERN = /\A[a-z][a-z0-9]*(?:_[a-z0-9]+)*_?\z/

      # Returns field names reserved by this adapter.
      #
      # ActiveSearch.define_index refuses a declaration using one of these names. The default is an
      # empty frozen Array.
      def self.reserved_field_names
        [].freeze
      end

      ##
      # :attr_reader: options
      #
      # Returns this store's configured options without +:index_prefix+.
      attr_reader :options

      # Initializes the adapter with store options and returns a new instance.
      #
      # ==== Options
      #
      # * +:index_prefix+ - Prepends a valid lowercase prefix to every store index name.
      # * Other options remain in #options for the adapter or its client.
      def initialize(**options)
        @index_prefix = extract_index_prefix(options)
        @options = options
        @schema_observations = Schema::ObservationCache.new
      end

      # Returns the prefix prepended to each index name, or nil when none is configured.
      def index_prefix
        @index_prefix
      end

      # Prepares +document+, writes it to +index+, and returns the adapter result.
      #
      # ==== Options
      #
      # * +:routing+ - Supplies the routing value for an adapter that partitions documents.
      #
      # Typed stores narrow the document to observed fields. A schemaless adapter overrides the
      # internal preparation step to retain the complete document. Declared client errors become
      # AdapterError.
      def add(index, document, routing: nil)
        translating_errors { write(index, prepare_document(index, document, routing: routing), routing: routing) }
      end

      # Deletes +id+ from +index+ and returns the adapter result.
      #
      # ==== Options
      #
      # * +:routing+ - Supplies the routing value for an adapter that partitions documents.
      #
      # Declared client errors become AdapterError.
      def remove(index, id, routing: nil)
        translating_errors { delete(index, id, routing: routing) }
      end

      # Prepares and writes a Batch operation list, then returns the adapter result.
      #
      # Adapter-specific keyword options are forwarded to the required #flush implementation.
      # Declared client errors become AdapterError.
      def flush_batch(index, operations, **options)
        translating_errors { flush(index, prepare_operations(index, operations), **options) }
      end

      # What the store says this index holds, cached per process. Raises the store's own errors.
      def observed_schema(index, domain: nil) # :nodoc:
        schema_observations.fetch(schema_observation_key(index, domain)) { observe_for(index, domain) }
      end

      # Forgets what the store said, after a migration or a schema change. Without a domain it
      # clears every domain of the index, whose observations must not outlive the index itself.
      def reset_schema_cache(index = nil, domain: nil) # :nodoc:
        if index.nil?
          schema_observations.reset
        elsif domain
          schema_observations.reset(schema_observation_key(index, domain))
        else
          schema_observations.reset_matching { |key| key.first == index.index_name }
        end
      end

      # Removes every document matching a filter. Returns the number removed.
      def remove_by_filter(index, query_context, routing: nil)
        translating_errors { delete_by_filter(index, query_context, routing: routing) }
      end

      # Routing is passed in rather than read back from the context: an adapter that picks a table
      # or a partition from it needs it at build time.
      def build_query(index, query_context, routing: nil)
        raw = build_raw_query(index, query_context, routing: routing)
        query_context.modifiers.reduce(raw) { |q, mod| mod.call(q) }
      end

      # A store whose totals may be approximate needs an extra hit to settle next?.
      def fetch_one_extra?(query_context) # :nodoc:
        capabilities.approximate_totals? && !query_context.limit.nil? && room_for_extra?(query_context)
      end

      # The extra hit must remain within the store's page limit.
      def room_for_extra?(query_context) # :nodoc:
        window = capabilities.max_result_window
        window.nil? || (query_context.offset.to_i + query_context.limit + 1) <= window
      end

      # An unlimited query cannot be checked against an unstated backend page size.
      def ensure_within_result_window!(query_context) # :nodoc:
        window = capabilities.max_result_window
        return if window.nil?

        offset = query_context.offset.to_i
        last = offset + query_context.limit.to_i
        return if last <= window && offset < window

        raise ResultWindowExceeded,
          "#{self.class.name.demodulize} pages to #{window} results and this query asks for " \
          "#{last}. Narrow the search, or page from a sort key instead of an offset."
      end

      def context_with_extra_hit(query_context) # :nodoc:
        fetch_one_extra?(query_context) ? query_context.with(limit: query_context.limit + 1) : query_context
      end

      # Returns <tt>{ total:, results: [ { id:, score:, fields:, highlights: } ], fetched_extra_hit: }</tt>,
      # carrying through the +total_relation+, +partial_results+ and +store_metrics+ execute_query
      # supplied. Everything but +fetched_extra_hit+ is execute_query's own contract: +total+ and
      # +results+ are required, the other three default in Query, and a hit without +fields+ raises
      # from projection below.
      #
      # The query is built outside the error translation, so a caller's native block raises on its
      # own terms.
      def search(index, query_context, routing: nil)
        ensure_within_result_window!(query_context)
        fetching = context_with_extra_hit(query_context)
        raw_query = build_query(index, fetching, routing: routing)
        response = translating_errors { execute_query(index, raw_query, fetching, routing: routing) }
        project_hit_fields(response, query_context.hit_fields || index.definition.field_names)
          .merge(fetched_extra_hit: fetch_one_extra?(query_context))
      end

      # Makes completed writes visible to searches and returns the adapter's refresh result.
      #
      # The default implementation returns nil. Override this when the backend delays search
      # visibility after a successful write.
      def refresh(index_name)
      end

      # Returns true or false to report whether the backend is responding.
      #
      # The health task treats the result as authoritative. Subclasses must implement this method.
      def ping
        raise NotImplementedError
      end

      # Returns the Capabilities supported by this adapter.
      #
      # Subclasses must implement this method.
      def capabilities
        raise NotImplementedError
      end

      # Returns casters keyed by declared field type for values read from the store.
      #
      # The default is an empty Hash. Override this when the backend returns a different Ruby
      # representation, such as an epoch integer for a datetime or a String for a number.
      def type_casters
        @type_casters ||= {}
      end

      private
        # Removed from the options before an adapter forwards them to its client, which may reject
        # an unknown keyword outright. Redis.new does.
        def extract_index_prefix(options)
          prefix = options.delete(:index_prefix)

          if prefix.nil? || (prefix.is_a?(String) && prefix.empty?)
            nil
          elsif prefix.is_a?(String) && INDEX_PREFIX_PATTERN.match?(prefix)
            prefix
          else
            raise ConfigurationError,
              "Invalid index_prefix #{prefix.inspect}: use lowercase letters and digits in " \
              "single-underscore groups, as in \"development_\"."
          end
        end

        # The store governs the write: narrow to what it holds. A schemaless adapter overrides
        # this to send the whole document.
        def prepare_document(index, document, routing: nil)
          ensure_searchable(index, document.narrow_to(observed_field_names(index, routing: routing)))
        end

        # Narrowing away every searchable field is a migration gap, not a writable subset: the row
        # would be unfindable by any text query, so refuse the write rather than lose it silently.
        def ensure_searchable(index, narrowed)
          if narrowed.search_fields.empty? && index.definition.search_fields.any?
            raise UnsearchableWriteError,
              "#{index.index_name} holds none of the searchable fields " \
              "(#{index.definition.search_fields.join(', ')}). Migrate the store, then retry the write."
          end
          narrowed
        end

        def observed_field_names(index, routing: nil)
          observed_schema(index, domain: schema_domain(index, routing)).map(&:name)
        end

        # A sharded adapter maps routing to its shard here. The domain doubles as a cache key, so it
        # must be a stable scalar such as a table name, never a process object.
        def schema_domain(index, routing)
          nil
        end

        def observe_for(index, domain)
          observe_index(index)
        end

        def prepare_operations(index, operations)
          operations.map do |operation, args|
            if operation == :add
              document, routing = args
              [ operation, [ prepare_document(index, document, routing: routing), routing ] ]
            else
              [ operation, args ]
            end
          end
        end

        attr_reader :schema_observations

        def schema_observation_key(index, domain)
          [ index.index_name, domain ]
        end

        # Symbolized first, because slicing string keys by symbol names drops every field silently.
        def project_hit_fields(response, field_names)
          results = response[:results].map do |hit|
            hit.merge(fields: hit[:fields].symbolize_keys.slice(*field_names))
          end

          response.merge(results: results)
        end

        # Writes +document+ to +index+ and returns the backend result.
        #
        # Subclasses must implement this method. The +routing:+ keyword must be accepted even when
        # the backend does not use it.
        def write(index, document, routing: nil)
          raise NotImplementedError
        end

        # Deletes +id+ from +index+ and returns the backend result.
        #
        # Subclasses must implement this method. The +routing:+ keyword must be accepted even when
        # the backend does not use it.
        def delete(index, id, routing: nil)
          raise NotImplementedError
        end

        # Writes a Batch operation list and returns the backend result.
        #
        # Subclasses must implement this method and may accept adapter-specific +options+.
        def flush(index, operations, **options)
          raise NotImplementedError
        end

        # Kept under the smallest page a supported backend will serve: Typesense rejects a per_page
        # above 250. An adapter with a lower cap overrides this.
        def delete_batch_size
          100
        end

        # Pages through the matches and deletes each by id. Correct everywhere, slower than a native
        # delete-by-query, which the adapters that have one override this to use.
        #
        # No offset: each pass takes the first page of whatever still matches. The same first id
        # twice means a delete did not take, so raise rather than loop forever.
        def delete_by_filter(index, query_context, routing: nil)
          removed = 0
          previous_first = nil

          loop do
            page = search(index, query_context.with(limit: delete_batch_size), routing: routing)

            # A partial page hides matches this loop will never see, so it would end at an empty
            # page and report success while documents remain.
            if page[:partial_results]
              raise AdapterError,
                "remove_by_filter aborted: #{self.class.name.demodulize} answered with partial " \
                "results, so some matching documents may not have been seen"
            end

            ids = page[:results].filter_map { |row| row[:id] }
            break if ids.empty?

            if ids.first == previous_first
              raise AdapterError,
                "remove_by_filter cannot make progress: #{self.class.name.demodulize} still " \
                "returns #{ids.first} after deleting it"
            end

            previous_first = ids.first
            ids.each { |id| delete(index, id, routing: routing) }
            removed += ids.size

            refresh(index.index_name)
          end

          removed
        end

        # A declared exception becomes AdapterError, with the original on +cause+.
        def translating_errors
          client_errors = self.class::CLIENT_ERRORS
          return yield if client_errors.empty?

          begin
            yield
          rescue *client_errors => e
            # The class, not the message: RSolr::Error::Http#message builds itself from a response
            # it may not have, and raises from inside this handler. Detail stays on cause.
            raise AdapterError, "#{self.class.name.demodulize} request failed: #{e.class.name}"
          end
        end

        # Builds and returns the backend's native request for +query_context+.
        #
        # Subclasses must implement this method. The required +routing:+ keyword makes routing an
        # explicit part of request construction.
        def build_raw_query(index, query_context, routing:)
          raise NotImplementedError
        end

        # Returns the original id if it is not a GlobalID.
        def gid_to_model_id(id)
          gid = GlobalID.parse(id)
          gid ? "#{gid.model_class.name}/#{gid.model_id}" : id
        end

        # Only converts when the first segment looks like a class name, so a standalone document
        # id passes through unchanged.
        def model_id_to_gid(model_id, app: GlobalID.app)
          model_name, record_id = model_id.to_s.split("/", 2)
          return model_id unless model_name.present? && record_id.present?
          return model_id unless model_name.match?(/\A[A-Z]/)
          "gid://#{app}/#{model_name}/#{record_id}"
        end

        # Executes +raw_query+ and returns the normalized response Hash used by #search.
        #
        # The Hash requires +:total+ and +:results+. Each result requires +:id+, +:score+,
        # +:fields+, and +:highlights+. It may also include +:total_relation+, +:partial_results+,
        # and +:store_metrics+. Subclasses must implement this method.
        def execute_query(index, raw_query, query_context, routing: nil)
          raise NotImplementedError
        end

        def parse_sort(sort)
          case sort
          when Symbol, String
            [ sort.to_sym, :asc ]
          when Hash
            [ sort.keys.first.to_sym, sort.values.first ]
          end
        end

        def snippet_chars_for(field_opts)
          case field_opts.snippet_unit
          when :default
            Highlighting::FieldOptions::DEFAULT_SNIPPET_CHARS
          when :characters
            field_opts.snippet_value.to_i
          end
        end

        def snippet_words_for(field_opts)
          case field_opts.snippet_unit
          when :default
            Highlighting::FieldOptions::DEFAULT_SNIPPET_WORDS
          when :words
            field_opts.snippet_value.to_i
          end
        end
    end
  end
end
