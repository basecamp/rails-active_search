require "typesense"

module ActiveSearch
  module StoreAdapters
    # Store adapter for Typesense, selected with <tt>adapter: typesense</tt>.
    #
    # Uses the +typesense+ gem, with one collection per index.
    #
    # ==== Options
    #
    # * +:api_key+ - Required. The adapter raises without it.
    # * +:nodes+ - An Array of <tt>{ host:, port:, protocol: }</tt> Hashes. Defaults to +localhost+
    #   on port 8108 over HTTP.
    # * +:timeout+ - The connection timeout in seconds. Defaults to 5.
    #
    # A page holds at most 250 results, the server's own limit.
    class Typesense < Base
      # :stopdoc:
      # The serializer builds an internal "id" and merges declared data over it, so a declared id
      # would overwrite document identity.
      def self.reserved_field_names
        %i[ id ].freeze
      end

      extend ActiveSupport::Autoload

      eager_autoload do
        autoload :QueryBuilding
        autoload :ResponseParsing
        autoload :Serialization
        autoload :Highlighting
      end

      include QueryBuilding, ResponseParsing, Serialization, Highlighting

      def initialize(**options)
        super
        @client = build_client
      end

      CLIENT_ERRORS = [ ::Typesense::Error ].freeze

      def write(index, document, routing: nil)
        doc = document_body(document)
        collection(index.index_name).documents.upsert(doc)
      end

      def delete(index, id, routing: nil)
        doc_id = gid_to_model_id(id)
        collection(index.index_name).documents[doc_id.to_s].delete
      rescue ::Typesense::Error::ObjectNotFound
        # Already deleted
      end

      def flush(index, operations, **) # :nodoc:
        return if operations.empty?

        operations.each do |operation, args|
          case operation
          when :add
            document, routing = args
            add(index, document, routing: routing)
          when :remove
            id, routing = args
            remove(index, id, routing: routing)
          end
        end
      end

      # Nothing to do: Typesense indexes synchronously.
      def refresh(index_name)
      end

      def ping
        @client.health.retrieve["ok"] == true
      rescue
        false
      end

      NATIVE_TYPES = { text: "string", string: "string", integer: "int64", float: "float",
                       boolean: "bool", date: "int64", datetime: "int64" }.freeze

      # A collection carries a field schema, so both directions are exact here.
      def creation_plan(index)
        fields = index.definition.fields.map do |field|
          type = NATIVE_TYPES.fetch(field.type)
          type = "#{type}[]" if field.multiple?

          # sort: true only on a scalar string. Typesense sorts a number unasked and refuses the
          # flag on an array, but a string it was not told about cannot be sorted at all.
          { name: field.name.to_s, type: type, optional: true, facet: field.filterable? }
            .merge(type == "string" ? { sort: true } : {})
        end

        Schema::CreationPlan.new(index_name: index.index_name, native: { name: index.index_name.to_s, fields: fields },
          describes: fields.to_h { |field| [ field[:name], field[:type] ] })
      end

      def apply_creation_plan(plan)
        client.collections.create(plan.native)
      end

      def observe_index(index)
        collection(index.index_name).retrieve["fields"].flat_map { |field| observe_field(field) }
      end

      def missing_index?(error)
        error.is_a?(::Typesense::Error::ObjectNotFound)
      end

      def perform_drop(index)
        collection(index.index_name).delete
      rescue ::Typesense::Error::ObjectNotFound
        nil
      end

      def expected_native_type(field)
        type = NATIVE_TYPES[field.type]
        field.multiple? ? "#{type}[]" : type
      end

      def capabilities
        @capabilities ||= Capabilities.new(
          index_creation: true,
          highlight_snippet_units: [ :words ],
          highlight_per_field_snippets: false,
          missing_filters: false
        )
      end

      def type_casters
        @type_casters ||= {
          datetime: ActiveSearch::Type::EpochMicrosecondsDateTime.new,
          date: ActiveSearch::Type::EpochSecondsDate.new
        }
      end

      # The Typesense client, for anything this adapter does not offer.
      attr_reader :client

      # Typesense rejects a larger page as a backend error, so the cap is named here instead.
      PER_PAGE_LIMIT = 250

      private
        def build_raw_query(index, query_context, routing:)
          if query_context.limit && query_context.limit > PER_PAGE_LIMIT
            raise UnsupportedOperationError,
              "Typesense serves at most #{PER_PAGE_LIMIT} results per page and this query asks " \
              "for #{query_context.limit}. Lower the limit and page with offset."
          end

          highlight_fields = ActiveSearch::Highlighting.fields_for(query_context.fields, query_context.highlight_opts)
          search_params = build_search_params(query_context, highlight_fields, index.definition)
          search_params[:limit] = query_context.limit if query_context.limit
          search_params[:offset] = query_context.offset if query_context.offset

          # id is always included, because the hit's id is the document identity.
          if query_context.hit_fields.present?
            search_params[:include_fields] = ([ "id" ] + query_context.hit_fields.map(&:to_s)).uniq.join(",")
          end

          search_params
        end

        def execute_query(index, raw_query, query_context, routing: nil)
          response = collection(index.index_name).documents.search(raw_query)
          highlight_fields = raw_query[:highlight_fields]&.split(",")&.map(&:to_sym) || []
          parse_response(response, query_context.highlight_opts, highlight_fields)
        end

        def build_client
          api_key = options[:api_key]

          if api_key.blank?
            raise ConfigurationError,
              "Typesense requires an api_key. Set it in config/search.yml for this store."
          end

          ::Typesense::Client.new(
            nodes: options[:nodes] || [ { host: "localhost", port: 8108, protocol: "http" } ],
            api_key: api_key,
            connection_timeout_seconds: options[:timeout] || 5
          )
        end

        # An indexed string is both searched and filtered here, so one role would refuse whichever
        # of the two a declaration asked for. It gets an observation per role it really supports.
        def observe_field(field)
          roles = if field["index"] == false
            []
          elsif field["type"].to_s.start_with?("string")
            %i[ searchable filterable ]
          else
            [ :filterable ]
          end

          roles.map do |role|
            Schema::Observation.new(name: field["name"], role: role, native_type: field["type"])
          end
        end

        def collection(index_name)
          @client.collections[index_name.to_s]
        end
    end
  end
end
