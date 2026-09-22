require "meilisearch"

module ActiveSearch
  module StoreAdapters
    # Store adapter for Meilisearch, selected with <tt>adapter: meilisearch</tt>.
    #
    # Uses the +meilisearch+ gem.
    #
    # ==== Options
    #
    # * +:url+ - The server URL. Defaults to <tt>http://localhost:7700</tt>.
    # * +:api_key+ - The API key, when the server requires one.
    # * +:max_result_window+ - The store's largest <tt>offset + limit</tt>.
    #
    # Every write is a task the server applies asynchronously. A read sees the write only after
    # #refresh, and a task that failed raises there rather than at the write.
    class Meilisearch < Base
      # :stopdoc:
      # The serializer builds the primary-key "id" and merges declared data over it, so a declared
      # id would overwrite document identity.
      def self.reserved_field_names
        %i[ id ].freeze
      end

      # The default searchableAttributes of an index this gem did not configure.
      WILDCARD = "*".freeze

      extend ActiveSupport::Autoload

      eager_autoload do
        autoload :QueryBuilding
        autoload :ResponseParsing
      end

      include QueryBuilding, ResponseParsing

      def initialize(**options)
        super
        @client = build_client
        @pending_tasks = {}
        @pending_tasks_lock = Mutex.new
      end

      CLIENT_ERRORS = [ ::Meilisearch::ApiError, ::Meilisearch::CommunicationError,
                        ::Meilisearch::TimeoutError ].freeze

      # The client polls every 50ms by default, which rounds every wait up to the next 50ms.
      #
      # The timeout is a budget per task rather than per wait: a backlog of n tasks legitimately
      # takes n times as long as one.
      WAIT_TIMEOUT_MS = 5_000
      WAIT_INTERVAL_MS = 5

      def write(index, document, routing: nil)
        task = index_for(index.index_name).add_documents([ document_body(document) ])
        track_task(index.index_name, task["taskUid"])
      end

      def delete(index, id, routing: nil)
        doc_id = encode_id(gid_to_model_id(id))
        task = index_for(index.index_name).delete_document(doc_id)
        track_task(index.index_name, task["taskUid"])
      rescue ::Meilisearch::ApiError => e
        # Not the already-deleted path: a missing document enqueues a task that succeeds with
        # deletedDocuments 0, and a missing index fails the task rather than 404ing.
        raise unless e.http_code == 404
      end

      def flush(index, operations, **) # :nodoc:
        return if operations.empty?

        # Runs of one operation type, in the caller's order. The engine applies tasks in submission
        # order, so grouping by type would let a delete overtake a later add of the same id.
        tasks = operations.chunk_while { |(a, _), (b, _)| a == b }.map do |run|
          if run.first.first == :add
            index_for(index.index_name).add_documents(run.map { |_, (document, _)| document_body(document) })
          else
            index_for(index.index_name).delete_documents(run.map { |_, (id, _)| encode_id(gid_to_model_id(id)) })
          end
        end

        tasks.each { |task| await(task) }
      end

      # Translated here: refresh does not pass through the write wrappers, so a wait timeout would
      # otherwise reach callers as the raw client exception.
      def refresh(index_name)
        translating_errors { wait_for_pending_tasks(index_name) }
      end

      def ping
        @client.health["status"] == "available"
      rescue
        false
      end

      # Meilisearch has no per-field types. What it has is which attributes are searchable,
      # filterable and sortable, which is exactly what the declaration says.
      def creation_plan(index)
        searchable = index.definition.search_fields.map(&:to_s)
        filterable = index.definition.filter_fields.keys.map(&:to_s)

        native = { searchable_attributes: searchable, filterable_attributes: filterable,
                   sortable_attributes: sortable_names(index) }

        Schema::CreationPlan.new(index_name: index.index_name, native: native,
          describes: searchable.index_with("searchable").merge(filterable.index_with("filterable")))
      end

      # Both calls are tasks, so both are awaited: settings that land after the caller looks read as
      # an index missing its own declaration.
      def apply_creation_plan(plan)
        translating_errors do
          await client.create_index(plan.index_name.to_s, { primary_key: "id" })
          await client.index(plan.index_name.to_s).update_settings(plan.native)
        end
      end

      # Meilisearch has no field schema, only settings naming which attributes are searchable and
      # filterable, so this can find a missing declaration but cannot confirm a present one.
      def observe_index(index)
        settings = client.index(index.index_name.to_s).settings

        observations_for(searchable_names(settings, index), :searchable) +
          observations_for(Array(settings["filterableAttributes"]), :filterable) +
          observations_for(Array(settings["sortableAttributes"]), :sortable)
      end

      # A wildcard claims every attribute is searchable, so every declared one is; the store just
      # cannot name them back.
      def searchable_names(settings, index) # :nodoc:
        searchable = Array(settings["searchableAttributes"])

        searchable == [ WILDCARD ] ? index.definition.search_fields.map(&:to_s) : searchable
      end

      # A field missing from sortableAttributes raises on the first sort. Collections are left out:
      # a query cannot sort one, so requiring it would fail a correctly configured index.
      def schema_requirements(index)
        super + sortable_names(index).map do |name|
          Schema::Requirement.new(field: name.to_sym, role: :sortable, name: name)
        end
      end

      def sortable_names(index) # :nodoc:
        index.definition.fields.reject { |field| field.searchable? || field.multiple? }
          .map { |field| field.name.to_s }
      end

      def missing_index?(error)
        error.is_a?(::Meilisearch::ApiError) && error.http_code == 404
      end

      # Dropping a missing index arrives as a failed task rather than an ApiError, and must stay
      # tolerable or drop loses its idempotency. The ApiError rescue sits inside translating_errors,
      # which would otherwise have turned it into an AdapterError first.
      def perform_drop(index)
        translating_errors do
          await client.delete_index(index.index_name.to_s), allow: [ "index_not_found" ]
        rescue ::Meilisearch::ApiError => e
          raise unless e.http_code == 404
        end
      end

      def capabilities
        @capabilities ||= Capabilities.new(
          index_creation: true,
          highlight_snippet_units: [ :words ],
          operator: false,
          # Meilisearch returns estimatedTotalHits, which is an estimate rather than a count.
          approximate_totals: true,
          # maxTotalHits truncates silently: past it a page comes back short while the estimate
          # still reports the full count. An index configured higher passes the same setting here.
          max_result_window: options.fetch(:max_result_window, 1_000)
        )
      end

      def type_casters
        @type_casters ||= {
          datetime: ActiveSearch::Type::EpochMicrosecondsDateTime.new,
          date: ActiveSearch::Type::EpochSecondsDate.new
        }
      end

      # The Meilisearch client, for anything this adapter does not offer.
      attr_reader :client

      private
        # Schemaless: no field-level mapping to narrow to, so the whole document is written.
        def prepare_document(index, document, routing: nil)
          document
        end

        def observations_for(names, role)
          names.map { |name| Schema::Observation.new(name: name, role: role) }
        end

        def build_raw_query(index, query_context, routing:)
          highlight_fields = ActiveSearch::Highlighting.fields_for(query_context.fields, query_context.highlight_opts)
          search_params = build_search_params(query_context, highlight_fields, index.definition)
          search_params[:limit] = query_context.limit if query_context.limit
          search_params[:offset] = query_context.offset if query_context.offset

          # id is always retrieved, because the hit's id is the document identity.
          if query_context.hit_fields.present?
            search_params[:attributes_to_retrieve] = ([ "id" ] + query_context.hit_fields.map(&:to_s)).uniq
          end

          # The query goes through untouched: prefix matching and fuzziness are always on here and
          # cannot be controlled.
          { q: query_context.query.to_s, params: search_params }
        end

        def execute_query(index, raw_query, query_context, routing: nil)
          response = index_for(index.index_name).search(raw_query[:q], raw_query[:params])
          highlight_fields = raw_query.dig(:params, :attributes_to_highlight) || []
          parse_response(response, query_context.highlight_opts, highlight_fields)
        end

        def build_client
          url = options[:url] || "http://localhost:7700"
          api_key = options[:api_key]

          ::Meilisearch::Client.new(url, api_key)
        end

        # A handle, not a creation: creating on first write would give the index a primary key and
        # none of the declaration's settings.
        def index_for(index_name)
          @indices ||= {}
          @indices[index_name] ||= @client.index(index_name.to_s)
        end

        FAILED_TASK_STATUSES = %w[ failed canceled ].freeze

        def await(task, allow: [])
          settled! client.wait_for_task(task["taskUid"]), allow: allow
        end

        # A terminal task that did not succeed is a write that did not happen, so waiting is not
        # enough on its own: the status has to be read.
        def settled!(task, allow: [])
          if FAILED_TASK_STATUSES.include?(task["status"]) && !allow.include?(task.dig("error", "code"))
            raise AdapterError, "Meilisearch task #{task["uid"]} (#{task["type"]}) #{task["status"]}: " \
              "#{task.dig("error", "message") || "no error detail"}"
          end

          task
        end

        def track_task(index_name, task_uid)
          @pending_tasks_lock.synchronize { (@pending_tasks[index_name] ||= []) << task_uid }
        end

        # Only settled uids leave the list, and only after the wait: a timeout or a connection
        # failure keeps them for the next refresh, and a write landing during the wait stays too.
        # An emptied list keeps its key, because deleting it races a concurrent writer's append.
        def wait_for_pending_tasks(index_name)
          waited = @pending_tasks_lock.synchronize { @pending_tasks[index_name]&.dup }
          return if waited.blank?

          # Tasks settle in uid order, so waiting on the highest is one wait for the whole batch.
          # It proves the rest are terminal, never that they succeeded, hence the status query.
          @client.wait_for_task(waited.max, WAIT_TIMEOUT_MS * waited.size, WAIT_INTERVAL_MS)
          failed = @client.tasks(uids: waited, statuses: FAILED_TASK_STATUSES)["results"]

          # A failed task is dropped before it raises: waiting on it again cannot change its
          # status, only repeat the same error forever.
          @pending_tasks_lock.synchronize { @pending_tasks[index_name]&.reject! { |uid| waited.include?(uid) } }
          failed.each { |task| settled!(task) }
        end

        # Meilisearch only allows alphanumerics, hyphens and underscores in an id. Everything else
        # is escaped as -hh per UTF-8 byte, with - itself doubled to keep the mapping bijective.
        def encode_id(id)
          encoded = id.to_s.gsub(/[^A-Za-z0-9_]/) do |ch|
            ch == "-" ? "--" : ch.bytes.map { |byte| format("-%02x", byte) }.join
          end

          if encoded.empty?
            raise DocumentError, "Meilisearch requires a non-empty document id, so #{id.inspect} cannot be stored or addressed"
          end

          encoded
        end

        # Escapes decode to raw bytes, so the string is rebuilt binary and read back as UTF-8.
        def decode_id(id)
          id.to_s.b.gsub(/-(-|[0-9a-f]{2})/) do
            $1 == "-" ? "-" : $1.to_i(16).chr
          end.force_encoding(Encoding::UTF_8)
        end

        def document_body(document)
          # Meilisearch counts a null as existing, so writing one makes "field NOT EXISTS" false for
          # a document that has no value. An add-or-replace clears an omitted field anyway.
          supplied = document.data.reject { |_name, value| value.nil? }
          serialized = supplied.transform_values { |v| serialize_value(v) }

          { "id" => encode_id(gid_to_model_id(document.id)) }.merge(serialized.stringify_keys)
        end

        def serialize_value(value)
          case value
          when Time, DateTime, ActiveSupport::TimeWithZone
            type_casters[:datetime].serialize(value)
          when ::Date
            type_casters[:date].serialize(value)
          when Hash
            value.transform_values { |v| serialize_value(v) }
          when Array
            value.map { |v| serialize_value(v) }
          else
            value
          end
        end

        def extract_highlights(formatted, opts, highlight_fields)
          highlight_fields.each_with_object({}) do |field, h|
            field_opts = opts.for_field(field)
            value = formatted[field.to_s]
            next unless value.is_a?(String)

            fragment = ActiveSearch::Highlighting.fragment(value, field_opts)
            h[field] = fragment if fragment
          end
        end
    end
  end
end
