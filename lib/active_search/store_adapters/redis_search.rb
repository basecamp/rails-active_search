require "redis"

module ActiveSearch
  module StoreAdapters
    # Store adapter for RediSearch, selected with <tt>adapter: redis_search</tt>.
    #
    # Uses the +redis+ gem, with one FT index per ActiveSearch index over hashes keyed
    # <tt><index>:<id></tt>.
    #
    # ==== Options
    #
    # Every option is passed to <tt>Redis.new</tt>. +:host+ defaults to +localhost+, +:port+ to 6379,
    # and +:db+ to 0.
    #
    # An application that writes its own FT schema must declare every collection field with
    # <tt>SEPARATOR</tt> set to the unit separator character (<tt>"\x1f"</tt>), which is what this
    # adapter joins a collection on.
    class RedisSearch < Base
      # :stopdoc:
      # A TAG field is one string Redis Search splits on a separator, so a collection is written
      # joined by one. U+001F is the ASCII unit separator, picked because an indexable value cannot
      # contain it where a comma, the Redis default, easily could.
      COLLECTION_SEPARATOR = "\x1f".freeze

      extend ActiveSupport::Autoload

      eager_autoload do
        autoload :QueryBuilding
        autoload :ResponseParsing
        autoload :Serialization
      end

      include QueryBuilding, ResponseParsing, Serialization

      def initialize(**options)
        super
        @client = build_client
      end

      CLIENT_ERRORS = [ ::Redis::BaseError ].freeze

      def write(index, document, routing: nil)
        replace_document(client, index, document)
      end

      def delete(index, id, routing: nil)
        client.del(document_key(index, id))
      end

      def flush(index, operations, **) # :nodoc:
        return if operations.empty?

        client.pipelined do |pipeline|
          operations.each do |operation, args|
            case operation
            when :add    then replace_document(pipeline, index, args.first)
            when :remove then pipeline.del(document_key(index, args.first))
            end
          end
        end
      end

      # Nothing to do: RediSearch indexes synchronously.
      def refresh(index_name)
      end

      def ping
        client.ping == "PONG"
      rescue
        false
      end

      MISSING_INDEX = /unknown index|no such index/i

      # FT.INFO reports a separator for every TAG. A scalar one is created without a SEPARATOR
      # clause, so Redis applies its own default and reports that.
      DEFAULT_TAG_SEPARATOR = ","

      # ismissing() needs this on the field. Creation puts it on every filterable one, so a schema
      # built without it verifies clean and then cannot answer a missing filter.
      MISSING_FLAG = "INDEXMISSING".freeze

      NATIVE_TYPES = { text: "TEXT", string: "TAG", integer: "NUMERIC", float: "NUMERIC",
                       boolean: "TAG", date: "NUMERIC", datetime: "NUMERIC" }.freeze

      # A collection is TAG whatever it holds, because a NUMERIC field holds one number, and the
      # separator has to be the one the adapter joins on or Redis splits on its own comma.
      def creation_plan(index)
        schema = index.definition.fields.flat_map do |field|
          if field.multiple?
            [ field.name.to_s, "TAG", "SEPARATOR", COLLECTION_SEPARATOR, "INDEXMISSING" ]
          elsif field.searchable?
            [ field.name.to_s, "TEXT" ]
          else
            [ field.name.to_s, NATIVE_TYPES.fetch(field.type), "INDEXMISSING" ]
          end
        end

        native = [ index.index_name.to_s, "ON", "HASH", "PREFIX", 1, "#{index.index_name}:",
                   "SCHEMA", *schema ]

        Schema::CreationPlan.new(index_name: index.index_name, native: native,
          describes: index.definition.fields.to_h { |field| [ field.name.to_s, expected_native_type(field) ] })
      end

      def apply_creation_plan(plan)
        client.call("FT.CREATE", *plan.native)
      end

      # RESP2 answers a flat array of pairs and RESP3 a map, the same split parse_response already
      # handles. Each attribute arrives the same two ways.
      def observe_index(index)
        info = as_map(client.call("FT.INFO", index.index_name.to_s))

        Array(info["attributes"]).map do |attribute|
          field = as_map(attribute)
          separator = field["SEPARATOR"]

          type = field["type"] == "TAG" && separator ? "TAG(#{separator})" : field["type"]

          Schema::Observation.new(name: field["attribute"],
            native_type: with_missing_flag(type, Array(field["flags"]).include?(MISSING_FLAG)),
            role: field["type"] == "TEXT" ? :searchable : :filterable)
        end
      end

      # Redis says "Unknown index name" for one that is not there, which is an answer rather than a
      # failure to answer.
      def missing_index?(error)
        MISSING_INDEX.match?(error.message)
      end

      def as_map(reply) # :nodoc:
        reply.is_a?(Hash) ? reply : Hash[*reply]
      end

      def perform_drop(index)
        client.call("FT.DROPINDEX", index.index_name.to_s, "DD")
      rescue ::Redis::CommandError => e
        raise unless MISSING_INDEX.match?(e.message)
      end

      # The separator is part of what a TAG field is: a collection written with one separator and
      # read with another verifies compatible and then fails every collection filter.
      def expected_native_type(field)
        type = if field.multiple?
          "TAG(#{COLLECTION_SEPARATOR})"
        elsif NATIVE_TYPES[field.type] == "TAG"
          "TAG(#{DEFAULT_TAG_SEPARATOR})"
        else
          NATIVE_TYPES[field.type]
        end

        with_missing_flag(type, !field.searchable?)
      end

      def capabilities
        @capabilities ||= Capabilities.new(
          index_creation: true,
          highlight_snippet_units: [],
          highlight_per_field_markers: false,
          highlight_per_field_snippets: false,
          operator: false
        )
      end

      def type_casters
        # Redis stores everything as strings
        @type_casters ||= {
          integer: ActiveModel::Type::Integer.new,
          float: ActiveModel::Type::Float.new,
          boolean: ActiveModel::Type::Boolean.new,
          datetime: ActiveSearch::Type::EpochMicrosecondsDateTime.new,
          date: ActiveSearch::Type::EpochSecondsDate.new
        }
      end

      # The Redis client, for anything this adapter does not offer.
      attr_reader :client

      private
        # The FT schema indexes, the hash stores: a field absent from the schema is still written and
        # still comes back on a search, so narrowing to the observed names would drop it.
        def prepare_document(index, document, routing: nil)
          document
        end

        def with_missing_flag(type, flagged)
          flagged ? "#{type} #{MISSING_FLAG}" : type
        end

        def document_key(index, id)
          "#{index.index_name}:#{gid_to_model_id(id)}"
        end

        # HSET merges, so a declared field the document does not supply has to be deleted or its old
        # value survives the replacement.
        def replace_document(redis, index, document)
          key = document_key(index, document.id)
          fields = document_fields(document)
          absent = document.absent_fields.map(&:to_s)

          redis.hset(key, fields) if fields.any?
          redis.hdel(key, *absent) if absent.any?
        end

        def build_raw_query(index, query_context, routing:)
          highlight_fields = ActiveSearch::Highlighting.fields_for(query_context.fields, query_context.highlight_opts)
          search_query = build_search_query(query_context, index.definition)
          args = build_search_args(
            search_query,
            query_context.sort,
            highlight_fields,
            query_context.highlight_opts,
            query_context.limit,
            query_context.offset,
            query_context.hit_fields
          )
          { index_name: index.index_name, search_query: search_query, args: args, highlight_fields: highlight_fields }
        end

        def execute_query(index, raw_query, query_context, routing: nil)
          response = client.call("FT.SEARCH", index.index_name, *raw_query[:args])
          parse_response(response, query_context.highlight_opts, raw_query[:highlight_fields], index.index_name,
            index.definition)
        end

        def build_client
          Redis.new(**{ host: "localhost", port: 6379, db: 0 }.merge(options))
        end

        def extract_highlights(fields_hash, opts, highlight_fields)
          highlight_fields.each_with_object({}) do |field, h|
            fragment = ActiveSearch::Highlighting.fragment(fields_hash[field], opts.for_field(field))
            h[field] = fragment if fragment
          end
        end
    end
  end
end
