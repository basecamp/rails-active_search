require "rsolr"

module ActiveSearch
  module StoreAdapters
    # Store adapter for Solr, selected with <tt>adapter: solr</tt>.
    #
    # Uses the +rsolr+ gem, with one Solr core per index. Add +faraday-net_http_persistent+ to keep
    # one connection open across requests.
    #
    # ==== Options
    #
    # * +:url+ - The Solr base URL. Defaults to <tt>http://localhost:8983/solr</tt>.
    #
    # This is the one adapter that cannot create its own index: a core needs a configset the
    # declaration does not carry, so <tt>active_search:index:create</tt> refuses and the core must
    # exist in Solr first.
    class Solr < Base
      # :stopdoc:
      extend ActiveSupport::Autoload

      eager_autoload do
        autoload :QueryBuilding
        autoload :ResponseParsing
      end

      include QueryBuilding, ResponseParsing

      # RSolr::Error is a namespace module, not an ancestor: RSolr::Error::Http descends from
      # RuntimeError without including it, so rescuing the module would catch nothing. Http covers
      # InvalidResponse, InvalidJsonResponse, InvalidRubyResponse and Timeout, which descend from it.
      CLIENT_ERRORS = [ ::RSolr::Error::Http, ::RSolr::Error::ConnectionRefused ].freeze

      SOFT_COMMIT = { softCommit: true }.freeze

      # softCommit rides on the add rather than following it: one round trip instead of two, and a
      # soft commit opens a searcher without flushing to disk. refresh stays hard.
      def write(index, document, routing: nil)
        client(index.index_name).add([ document_body(document) ], params: SOFT_COMMIT)
      end

      def delete(index, id, routing: nil)
        doc_id = gid_to_model_id(id)
        client(index.index_name).delete_by_id(doc_id.to_s, params: SOFT_COMMIT)
      rescue RSolr::Error::Http => e
        # Already deleted.
        raise unless e.response[:status] == 404
      end

      def flush(index, operations, **) # :nodoc:
        return if operations.empty?

        # Runs of one operation type, in the caller's order. Solr applies updates in receipt order,
        # so grouping by type would let an add overtake an earlier remove and leave a ghost.
        committed = operations.chunk_while { |(a, _), (b, _)| a == b }.map do |run|
          if run.first.first == :add
            client(index.index_name).add(run.map { |_, (document, _)| document_body(document) }, params: SOFT_COMMIT)
            true
          else
            client(index.index_name).delete_by_id(run.map { |_, (id, _)| gid_to_model_id(id).to_s })
            false
          end
        end

        soft_commit(index.index_name) unless committed.last
      end

      def refresh(index_name)
        client(index_name).commit
      end

      def soft_commit(index_name) # :nodoc:
        client(index_name).soft_commit
      end

      # A server-level question, so it needs no core.
      def ping
        admin_client.get("admin/info/system").present?
      rescue
        false
      end

      # Solr's own fields, not the declaration's.
      RESERVED_FIELDS = /\A_|\Aid\z|\Ascore\z/

      # RESERVED_FIELDS as declarable names: the serializer builds "id" and every fl asks for
      # "score", so a declared either would collide with Solr's own.
      def self.reserved_field_names
        %i[ id score ].freeze
      end

      TEXT_CLASS = "solr.TextField".freeze

      STR   = "solr.StrField".freeze
      LONG  = "solr.LongPointField".freeze
      INT   = "solr.IntPointField".freeze
      FLOAT = "solr.FloatPointField".freeze
      DOUBLE = "solr.DoublePointField".freeze
      DATE  = "solr.DatePointField".freeze
      BOOL  = "solr.BoolField".freeze

      # The one class that serves a declared type. A StrField holds an id but orders it lexically,
      # and an IntPointField is 32-bit where this declaration is 64.
      FIELD_CLASSES = { text: TEXT_CLASS, string: STR, integer: LONG, float: DOUBLE,
                        boolean: BOOL, date: DATE, datetime: DATE }.freeze

      def observe_index(index)
        solr = client(index.index_name)
        classes = solr.get("schema/fieldtypes")["fieldTypes"].to_h { |type| [ type["name"], type["class"] ] }

        explicit = solr.get("schema/fields")["fields"].reject { |field| RESERVED_FIELDS.match?(field["name"]) }
          .map { |field| observation_for(field, classes) }

        explicit + dynamic_observations(index, solr, classes, explicit.map(&:name))
      end

      # A field served only by a <dynamicField> pattern is real and indexed, but schema/fields does
      # not list it, so a declared name matching a pattern would otherwise be stripped from writes.
      def dynamic_observations(index, solr, classes, explicit_names) # :nodoc:
        patterns = solr.get("schema/dynamicfields")["dynamicFields"]

        (index.definition.field_names.map(&:to_s) - explicit_names).filter_map do |name|
          rule = patterns.find { |pattern| dynamic_match?(pattern["name"], name) }
          observation_for(rule.merge("name" => name), classes) if rule
        end
      end

      # Solr allows one wildcard, leading or trailing.
      def dynamic_match?(pattern, name) # :nodoc:
        if pattern.start_with?("*")
          name.end_with?(pattern[1..])
        elsif pattern.end_with?("*")
          name.start_with?(pattern[0..-2])
        else
          pattern == name
        end
      end

      def observation_for(field, classes) # :nodoc:
        field_class = classes[field["type"]]

        Schema::Observation.new(name: field["name"],
          native_type: field_class && native_type_for(field_class, field["multiValued"]),
          role: role_for(field, field_class))
      end

      # A field type is named by whoever wrote the configset, so plong and text_general are a
      # convention rather than a promise. The class underneath them is Solr's own.
      def expected_native_type(field)
        field_class = FIELD_CLASSES[field.type]

        field_class && native_type_for(field_class, field.multiple?)
      end

      def missing_index?(error)
        error.is_a?(::RSolr::Error::Http) && error.response[:status] == 404
      end

      # index_creation stays at its false default: a core needs a configset, and the declaration
      # does not carry one.
      def capabilities
        @capabilities ||= Capabilities.new(
          # A range over a collection: one [a TO b] clause carries both bounds.
          collection_ranges: true,
          highlight_snippet_units: [ :characters ],
        )
      end

      def type_casters
        @type_casters ||= {
          datetime: ActiveModel::Type::DateTime.new,
          date: ActiveModel::Type::Date.new
        }
      end

      # The RSolr client for one core, for anything this adapter does not offer. Per core, because a
      # core is addressed by its own URL rather than named in a request.
      def client(index_name)
        @clients ||= {}
        @clients[index_name] ||= begin
          url = "#{base_url}/#{index_name}"
          connection = persistent_connection(url)
          connection ? RSolr.connect(connection, url: url) : RSolr.connect(url: url)
        end
      end

      # RSolr's Faraday adapter opens a TCP connection per request; this keeps one alive. Optional:
      # without the gem RSolr builds its own connection and the adapter works either way.
      #
      # Everything RSolr's builder sets up is repeated here, because swapping only the adapter drops
      # its middleware — and without raise_error a 400 arrives as an ordinary response, so a failed
      # write reads as a success.
      def persistent_connection(url) # :nodoc:
        require "faraday/net_http_persistent"

        uri = URI.parse(url)

        Faraday.new(url: url, request: { params_encoder: Faraday::FlatParamsEncoder }) do |conn|
          conn.request :authorization, :basic_auth, uri.user, uri.password if uri.user && uri.password
          conn.response :raise_error
          conn.adapter :net_http_persistent
        end
      rescue LoadError
        nil
      end

      private
        def base_url
          options[:url] || "http://localhost:8983/solr"
        end

        def admin_client
          @admin_client ||= RSolr.connect(url: base_url)
        end

        # A string field with indexed false still answers, because docValues does; a point field
        # with docValues false refuses a sort, which every filterable field must serve. Text needs
        # the inverted index either way.
        def role_for(field, field_class)
          if field_class == TEXT_CLASS
            :searchable unless field["indexed"] == false
          else
            :filterable unless field["docValues"] == false
          end
        end

        # Solr holds a collection in the same field type, so multiplicity has to ride along with
        # the class or a declared collection and a scalar compare equal.
        def native_type_for(field_class, multiple)
          multiple ? "#{field_class}[]" : field_class
        end

        def build_raw_query(index, query_context, routing:)
          highlight_fields = ActiveSearch::Highlighting.fields_for(query_context.fields, query_context.highlight_opts)
          params = build_search_params(query_context, highlight_fields)
          params[:rows] = query_context.limit if query_context.limit
          params[:start] = query_context.offset if query_context.offset

          fl_fields = if query_context.hit_fields.present?
            query_context.hit_fields.map(&:to_s) + [ "id", "score" ]
          else
            [ "*", "score" ]
          end
          params[:fl] = fl_fields.join(",")

          params
        end

        def execute_query(index, raw_query, query_context, routing: nil)
          response = client(index.index_name).get("select", params: raw_query)
          highlight_fields = raw_query["hl.fl"]&.split(",")&.map(&:to_sym) || []
          parse_response(response, query_context.highlight_opts, highlight_fields)
        end

        def document_body(document)
          doc = { "id" => gid_to_model_id(document.id) }
          document.data.each { |k, v| doc[k.to_s] = serialize_value(v) }
          doc
        end

        def serialize_value(value)
          case value
          when Time, DateTime, ActiveSupport::TimeWithZone
            value.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
          when ::Date
            # Solr accepts a bare date, but the canonical instant keeps writes symmetric with filters.
            value.strftime("%Y-%m-%dT00:00:00Z")
          when Hash
            value.transform_values { |v| serialize_value(v) }
          when Array
            value.map { |v| serialize_value(v) }
          else
            value
          end
        end

        def extract_highlights(doc_highlights, opts, highlight_fields)
          highlight_fields.each_with_object({}) do |field, h|
            fragment = ActiveSearch::Highlighting.fragment(doc_highlights[field.to_s]&.first,
              opts.for_field(field))
            h[field] = fragment if fragment
          end
        end
    end
  end
end
