module ActiveSearch
  module StoreAdapters
    # Everything Elasticsearch and OpenSearch share, which is all of it bar the client class and
    # the transport errors. Not itself an adapter name — config names one of the two subclasses.
    class Elastic < Base # :nodoc:
      extend ActiveSupport::Autoload

      eager_autoload do
        autoload :QueryBuilding
        autoload :ResponseParsing
      end

      include QueryBuilding, ResponseParsing

      class_attribute :client_class, :not_found_error, :default_port

      def initialize(**options)
        super
        @client = build_client
      end

      # Each subclass declares its client's errors after requiring that client: probing from here
      # would freeze [] whenever this file loads before the gem does.
      CLIENT_ERRORS = [].freeze

      # The gates below compare against this, and "10" < "8" as strings.
      def self.legacy_elasticsearch?(version = defined?(::Elasticsearch::VERSION) && ::Elasticsearch::VERSION)
        version ? Gem::Version.new(version) < Gem::Version.new("8") : false
      end

      def write(index, document, routing: nil)
        doc_id = gid_to_model_id(document.id)
        params = { index: index.index_name, id: doc_id, body: serialize_data(document.data) }
        params[:routing] = routing if routing
        client.index(**params)
      end

      def delete_by_filter(index, query_context, routing: nil)
        params = { index: index.index_name, body: { query: build_query(index, query_context, routing: routing)[:query] }, refresh: true }
        params[:routing] = routing_param(routing) if routing.present?

        response = client.delete_by_query(**params)
        data = response.respond_to?(:body) ? response.body : response
        failures = Array(data["failures"])

        # A 200 can carry a partial purge, and what was skipped still matches the filter.
        if data["timed_out"]
          raise AdapterError, "delete_by_query timed out after removing #{data["deleted"]} documents"
        elsif failures.any?
          raise AdapterError, "delete_by_query failed on #{failures.size} of its matches: #{failures.first}"
        end

        data["deleted"] || 0
      end

      def delete(index, id, routing: nil)
        doc_id = gid_to_model_id(id)
        params = { index: index.index_name, id: doc_id }
        params[:routing] = routing if routing
        client.delete(**params)
      rescue not_found_error
        # Already deleted
      end

      def flush(index, operations, **options) # :nodoc:
        return if operations.empty?

        body = operations.flat_map do |operation, args|
          case operation
          when :add
            document, routing = args
            doc_id = gid_to_model_id(document.id)
            [
              { index: { _index: index.index_name, _id: doc_id, routing: routing }.compact },
              serialize_data(document.data)
            ]
          when :remove
            id, routing = args
            doc_id = gid_to_model_id(id)
            [ { delete: { _index: index.index_name, _id: doc_id, routing: routing }.compact } ]
          end
        end

        raise_on_bulk_failures client.bulk(body: body, refresh: true, **options)
      end

      def raise_on_bulk_failures(response) # :nodoc:
        data = response.respond_to?(:body) ? response.body : response
        return response unless data["errors"]

        failed = data["items"].filter_map do |item|
          operation = item.values.first
          "#{operation["_id"]}: #{operation.dig("error", "reason") || operation["status"]}" if operation["error"]
        end

        raise PartialWriteError,
          "#{failed.size} of #{data["items"].size} documents failed to index. #{failed.first(3).join("; ")}"
      end

      NATIVE_TYPES = { text: "text", string: "keyword", integer: "long", float: "double",
                       boolean: "boolean", date: "date", datetime: "date" }.freeze

      # A plain mapping: every text field gets the engine's default analyser, because the
      # declaration says nothing about analysis.
      def creation_plan(index)
        properties = index.definition.fields.to_h do |field|
          [ field.name, { type: NATIVE_TYPES.fetch(field.type) } ]
        end

        Schema::CreationPlan.new(index_name: index.index_name, native: { mappings: { properties: properties } },
          describes: properties.transform_values { |spec| spec[:type] })
      end

      # A write through an alias goes to its write index alone, so during a rollover that index's
      # mapping is the one that counts. Intersecting it with the drained index would narrow a new
      # field out of every write until the swap.
      def observe_index(index)
        shared = write_target_mappings(index.index_name)
          .map { |entry| entry.dig("mappings", "properties") || {} }
          .reduce { |kept, other| kept.select { |name, spec| other[name] == spec } }

        (shared || {}).map { |name, spec| observe_field(name, spec) }
      end

      # The designated write index's mapping when the name is an alias with one; every backing
      # mapping otherwise, where the intersection is the only honest answer.
      def write_target_mappings(index_name) # :nodoc:
        mappings = client.indices.get_mapping(index: index_name)
        write_index = write_index_for(index_name, mappings.keys)

        write_index ? [ mappings[write_index] ] : mappings.values
      end

      def write_index_for(index_name, backing) # :nodoc:
        if backing != [ index_name.to_s ]
          aliases = client.indices.get_alias(name: index_name)
          backing.find { |name| aliases.dig(name, "aliases", index_name.to_s, "is_write_index") }
        end
      end

      def missing_index?(error)
        error.is_a?(self.class.not_found_error)
      end

      # text is analysed and searched; everything else is exact and filtered.
      # index: false answers 400 rather than nothing, so the field fills no role.
      def observe_field(name, spec) # :nodoc:
        role = :searchable if spec["type"] == "text"
        role ||= :filterable unless unfilterable?(spec)
        role = nil if spec["index"] == false

        Schema::Observation.new(name: name, role: role, native_type: spec["type"])
      end

      # Every filterable field must sort and must answer a missing filter. doc_values false refuses
      # a sort outright, and null_value indexes a nil as present, so a missing filter finds none of
      # the documents it should.
      def unfilterable?(spec) # :nodoc:
        spec["doc_values"] == false || spec.key?("null_value")
      end

      def apply_creation_plan(plan)
        translating_errors { client.indices.create(index: plan.index_name, body: plan.native) }
      end

      def refresh(index_name)
        client.indices.refresh(index: index_name)
      end

      def ping
        client.ping
      rescue
        false
      end

      def perform_drop(index)
        client.indices.delete(index: index.index_name.to_s)
      rescue not_found_error
        nil
      end

      # The one mapping that serves a declared type: a keyword holds an integer but orders it
      # lexically, so a 2..10 range answers nothing, and a 32-bit mapping refuses a value the
      # declaration allows.
      def expected_native_type(field)
        NATIVE_TYPES[field.type]
      end

      def capabilities
        @capabilities ||= Capabilities.new(
          index_creation: true,
          # A range over a collection: one range clause carries both bounds.
          collection_ranges: true,
          highlight_snippet_units: [ :characters ],
          search_subfields: true,
          search_string_fields: true,
          # hits.total.relation is "gte" once tracking is capped, so the total can be a
          # lower bound rather than a count.
          approximate_totals: true,
          max_result_window: options.fetch(:max_result_window, 10_000)
        )
      end

      def type_casters
        @type_casters ||= {
          datetime: EpochMillisecondsCaster.new,
          date: ActiveModel::Type::Date.new
        }
      end

      class EpochMillisecondsCaster # :nodoc:
        def cast(value)
          case value
          when Integer
            Time.at(value / 1000.0).utc
          when String
            Time.parse(value).utc
          else
            value
          end
        end
      end

      # The Elasticsearch or OpenSearch client, for anything this adapter does not offer.
      attr_reader :client

      private
        # A search or a delete-by-query can name several shards, which Elasticsearch takes as a
        # comma-separated list. A single-document write cannot, and gets its routing from the record.
        def routing_param(routing)
          Array(routing).map(&:to_s).join(",")
        end

        def build_raw_query(index, query_context, routing:)
          highlight_fields = ActiveSearch::Highlighting.fields_for(query_context.fields, query_context.highlight_opts)
          body = build_elastic_query(query_context, highlight_fields)
          body[:from] = query_context.offset if query_context.offset
          body[:size] = query_context.limit if query_context.limit

          if query_context.hit_fields.present?
            body[:_source] = query_context.hit_fields.map(&:to_s)
          end

          body
        end

        def execute_query(index, raw_query, query_context, routing: nil)
          params = { index: index.index_name, body: raw_query }
          params[:routing] = routing_param(routing) if routing.present?

          response = client.search(**params)
          highlight_fields = raw_query.dig(:highlight, :fields)&.keys || []
          parse_response(response, query_context.highlight_opts, highlight_fields)
        end

        def build_client
          client_options = {
            hosts: options[:hosts] || [ { host: "localhost", port: default_port } ],
            log: options[:log] || false,
            logger: ActiveSearch.logger
          }.compact

          # ES7 needs an explicit adapter, because typhoeus is not bundled.
          if self.class.legacy_elasticsearch?
            client_options[:adapter] = :net_http
          end

          if options[:client_options]
            client_options.merge!(options[:client_options])
          end

          if client_options[:selector_class].is_a?(String)
            client_options[:selector_class] = client_options[:selector_class].constantize
          end

          client_class.new(**client_options)
        end

        def serialize_data(data)
          data.transform_values { |v| serialize_value(v) }
        end

        def serialize_value(value)
          case value
          when Time, DateTime, ActiveSupport::TimeWithZone
            (value.to_f * 1000).to_i
          when ::Date
            value.iso8601
          when Hash
            value.transform_values { |v| serialize_value(v) }
          when Array
            value.map { |v| serialize_value(v) }
          else
            value
          end
        end

        def extract_highlights(raw_highlights, opts, highlight_fields)
          highlight_fields.each_with_object({}) do |field, h|
            name = field.to_s.delete_suffix(".*")
            text = raw_highlights[answering_key(raw_highlights, name)]&.first
            fragment = ActiveSearch::Highlighting.fragment(text, opts.for_field(field))
            h[name.to_sym] = fragment if fragment
          end
        end

        # Elasticsearch answers under whichever representation matched, and require_field_match
        # leaves the bare name empty when the match landed on a subfield. Where several subfields
        # answer the first wins, because the response does not carry the query's boosts.
        def answering_key(raw_highlights, name)
          if raw_highlights.key?(name)
            name
          else
            raw_highlights.keys.find { |key| key.start_with?("#{name}.") }
          end
        end
    end
  end
end
