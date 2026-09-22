require "net/http"
require "json"
require "digest"

module ActiveSearch
  module StoreAdapters
    # Store adapter for Manticore Search, selected with <tt>adapter: manticore</tt>.
    #
    # Talks to the HTTP JSON API directly, so there is no client gem to add.
    #
    # ==== Options
    #
    # * +:host+ - Defaults to +localhost+.
    # * +:port+ - Defaults to 9308.
    # * +:ssl+ - Uses HTTPS when true.
    # * +:open_timeout+, +:read_timeout+ - Connection timeouts in seconds.
    # * +:max_result_window+ - The store's largest <tt>offset + limit</tt>.
    #
    # Manticore attributes have no NULL: an unset text column reads back as <tt>""</tt> where every
    # other store returns nil. Filtering on a missing value is therefore unsupported.
    class Manticore < Base
      # :stopdoc:
      # CREATE TABLE emits declared names as columns, and every Manticore table already holds its
      # built-in bigint id -- the one query building addresses as "id".
      def self.reserved_field_names
        %i[ id ].freeze
      end

      extend ActiveSupport::Autoload

      eager_autoload do
        autoload :QueryBuilding
        autoload :ResponseParsing
        autoload :Serialization
      end

      include QueryBuilding, ResponseParsing, Serialization

      def initialize(**options)
        super
        @http = build_http
      end

      # Driven over plain HTTP, so failures arrive as socket or protocol errors. Timeout::Error is
      # separate: Net::OpenTimeout and Net::ReadTimeout are RuntimeErrors, under none of the rest.
      CLIENT_ERRORS = [
        ::Net::HTTPBadResponse, ::Net::ProtocolError, ::SocketError, ::SystemCallError,
        ::Timeout::Error, ::JSON::ParserError
      ].freeze

      def write(index, document, routing: nil)
        body = {
          table: table_name_for(index.index_name),
          id: encode_id(document.id),
          doc: document_body(document)
        }
        request("/replace", body)
      end

      def delete(index, id, routing: nil)
        body = {
          table: table_name_for(index.index_name),
          id: encode_id(id)
        }
        request("/delete", body)
      rescue => e
        raise unless e.message.include?("not found")
      end

      def flush(index, operations, **) # :nodoc:
        return if operations.empty?

        # One /bulk per run of one operation type, in the caller's order: within a single bulk a
        # delete does not see a replace from the same request, so a mixed batch has to cross
        # request boundaries.
        operations.chunk_while { |(a, _), (b, _)| a == b }.each do |run|
          lines = run.map do |operation, args|
            case operation
            when :add
              document, _routing = args
              { replace: { table: table_name_for(index.index_name), id: encode_id(document.id), doc: document_body(document) } }
            when :remove
              id, _routing = args
              { delete: { table: table_name_for(index.index_name), id: encode_id(id) } }
            end
          end

          ndjson = lines.map { |l| JSON.generate(l) }.join("\n") + "\n"
          request("/bulk", ndjson, content_type: "application/x-ndjson")
        end
      end

      # Nothing to do: Manticore indexes synchronously.
      def refresh(index_name)
      end

      def ping
        response = @http.get("/")
        response.code == "200"
      rescue
        false
      end

      RESERVED_COLUMNS = %w[ id _original_id ].freeze

      # datetime is bigint, not timestamp: a timestamp attribute is 32-bit whole seconds, and the
      # gem stores datetimes as epoch microseconds.
      NATIVE_TYPES = { text: "text", string: "string", integer: "bigint", float: "float",
                       boolean: "bool", date: "timestamp", datetime: "bigint" }.freeze

      # An integer collection is Manticore's only filterable one, and it is a multi-value attribute.
      def creation_plan(index)
        columns = index.definition.fields.map do |field|
          [ field.name, column_type_for(field) ]
        end

        native = "CREATE TABLE #{table_name_for(index.index_name)} " \
          "(_original_id string, #{columns.map { |name, type| "#{name} #{type}" }.join(", ")})"

        Schema::CreationPlan.new(index_name: index.index_name, native: native,
          describes: columns.to_h { |n, t| [ n.to_s, t ] })
      end

      def apply_creation_plan(plan)
        sql(plan.native)
      end

      # DESCRIBE answers rows of Field, Type and Properties. id and _original_id are Manticore's and
      # the adapter's own, not the declaration's.
      def observe_index(index)
        rows = Array(sql("DESCRIBE #{table_name_for(index.index_name)}").first&.dig("data"))

        rows.reject { |row| RESERVED_COLUMNS.include?(row["Field"]) }.map do |row|
          Schema::Observation.new(name: row["Field"], native_type: row["Type"],
            role: row["Type"] == "text" ? :searchable : :filterable)
        end
      end

      # A table that is not there comes back as a rejected query.
      def missing_index?(error)
        error.message.include?("no such table")
      end

      def perform_drop(index)
        sql("DROP TABLE IF EXISTS #{table_name_for(index.index_name)}")
      end

      # CREATE TABLE takes multi and multi64. DESCRIBE reports those two as mva and mva64, and every
      # other type by the name it was created with.
      REPORTED_TYPES = { "multi" => "mva", "multi64" => "mva64" }.freeze

      def expected_native_type(field)
        created = column_type_for(field)

        REPORTED_TYPES.fetch(created, created)
      end

      def capabilities
        @capabilities ||= Capabilities.new(
          index_creation: true,
          # A range over a collection: one range clause carries both bounds.
          collection_ranges: true,
          highlight_snippet_units: [ :characters ],
          highlight_per_field_markers: false,
          highlight_per_field_snippets: false,
          operator: false,
          missing_filters: false,
          # Manticore answers total_relation "gte" once its count is capped, so a total cannot be
          # assumed exact and next_page? cannot be answered by arithmetic on it.
          approximate_totals: true,
          # Sphinx caps at max_matches (1000 by default) and reports the cap as an approximate
          # total, so a page past it truncates silently. The window refuses it instead.
          max_result_window: options.fetch(:max_result_window, 1_000)
        )
      end

      def type_casters
        @type_casters ||= {
          datetime: ActiveSearch::Type::EpochMicrosecondsDateTime.new,
          date: ActiveSearch::Type::EpochSecondsDate.new
        }
      end

      # The Net::HTTP session this adapter posts to, for anything it does not offer.
      attr_reader :http

      private
        def table_name_for(index_name)
          index_name.to_s.gsub("-", "__")
        end

        def build_raw_query(index, query_context, routing:)
          highlight_fields = ActiveSearch::Highlighting.fields_for(query_context.fields, query_context.highlight_opts)
          body = build_search_body(index.index_name, query_context, highlight_fields)
          body[:limit] = query_context.limit if query_context.limit
          body[:offset] = query_context.offset if query_context.offset
          body[:_highlight_fields] = highlight_fields  # Not a Manticore parameter; execute_query deletes it

          # _original_id always comes back, because it carries the document's real id.
          if query_context.hit_fields.present?
            body[:_source] = query_context.hit_fields.map(&:to_s) + [ "_original_id" ]
          end

          body
        end

        def execute_query(index, raw_query, query_context, routing: nil)
          highlight_fields = raw_query.delete(:_highlight_fields) || []
          response = request("/search", raw_query)
          parse_response(response, query_context.highlight_opts, highlight_fields)
        end

        def build_http
          host = options[:host] || "localhost"
          port = options[:port] || 9308
          http = Net::HTTP.new(host, port)
          http.use_ssl = options.fetch(:ssl, false)
          http.open_timeout = options[:open_timeout] || 5
          http.read_timeout = options[:read_timeout] || 30
          http
        end

        def sql(query)
          request("/sql?mode=raw", "query=#{CGI.escape(query)}",
            content_type: "application/x-www-form-urlencoded")
        end

        def column_type_for(field)
          if field.multiple? && %i[ integer datetime ].include?(field.type)
            "multi64"
          elsif field.multiple?
            "json"
          else
            NATIVE_TYPES.fetch(field.type)
          end
        end

        def request(path, body, content_type: "application/json")
          req = Net::HTTP::Post.new(path)
          req["Content-Type"] = content_type

          if body.is_a?(String)
            req.body = body
          else
            req.body = JSON.generate(body)
          end

          response = @http.request(req)
          result = json_body(response)

          # Manticore reports a rejected query in an error body whatever the status, and its own
          # text is more use than the status. AdapterError directly, which translating_errors passes
          # through unchanged.
          if result.is_a?(Hash) && result["error"].present?
            raise AdapterError, "Manticore rejected the request: #{result["error"]}"
          elsif !response.is_a?(::Net::HTTPSuccess)
            raise AdapterError, "Manticore answered #{response.code} #{response.message}"
          end

          result
        end

        # Net::HTTP does not raise for a non-2xx, so a 503 from a proxy would otherwise read as an
        # empty result. Such a body need not be JSON either, and then the status is what explains it.
        def json_body(response)
          JSON.parse(response.body)
        rescue ::JSON::ParserError
          raise if response.is_a?(::Net::HTTPSuccess)
          {}
        end

        def extract_highlights(hit_highlights, opts, highlight_fields)
          highlight_fields.each_with_object({}) do |field, h|
            fragment = ActiveSearch::Highlighting.fragment(hit_highlights[field.to_s]&.first,
              opts.for_field(field))
            h[field] = fragment if fragment
          end
        end
    end
  end
end
