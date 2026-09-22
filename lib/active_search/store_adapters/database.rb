module ActiveSearch
  module StoreAdapters
    # Everything Sqlite, Mysql and Postgresql share: an index is a table in the application's own
    # schema, reached through Active Record. It is built by a migration the generator writes, never
    # by index:create. Not itself an adapter name — config names one of the three.
    class Database < Base # :nodoc:
      # id is the document table's primary key; score is the projection alias every query selects.
      # Declared here so all three answer alike: a declaration must not be valid against one engine
      # and refused by another.
      def self.reserved_field_names
        %i[ id score ].freeze
      end

      extend ActiveSupport::Autoload

      eager_autoload do
        autoload :DocumentClass
        autoload :MigrationSource
        autoload :QueryBuilding
      end

      include QueryBuilding

      CLIENT_ERRORS = [ ::ActiveRecord::StatementInvalid, ::ActiveRecord::ConnectionNotEstablished ].freeze

      # A declared integer is eight bytes. Rails reports :integer for a four-byte column too, and
      # the width only in the limit, so a value the declaration allows can overflow one.
      INTEGER_BYTES = 8
      SIZED_CLASSES = %w[ integer float ].freeze

      # What a column can hold, not how it was declared: a string in a text column meets a string.
      # No decimal, which reads back as a BigDecimal rather than a Float.
      COLUMN_CLASSES = { string: "string", text: "string", citext: "string",
                         integer: "integer", float: "float",
                         boolean: "boolean", date: "date", datetime: "datetime",
                         json: "json", jsonb: "jsonb" }.freeze

      def delete(index, id, routing: nil)
        m = model_for(index, routing: routing)
        m.where(index.source.storage_key(id)).delete_all
      end

      # Writes every named column, absent ones as nil: an upsert updates only the columns it is
      # given, so sending only the document's own keys would let a stale value survive. The caller
      # names the columns, because the three engines keep text in different places.
      def replacement_attributes(document, names)
        names.index_with { |name| document.data[name] }
      end

      def flush(index, operations, **)
        m = connection_model_for(index)
        if operations.any?
          m.connection.transaction do
            operations.each do |operation, args|
              case operation
              when :add
                document, routing = args
                write(index, document, routing: routing)
              when :remove
                id, routing = args
                delete(index, id, routing: routing)
              end
            end
          end
        end
      end

      # A table in the application's own schema is built by a migration: direct creation would be
      # neither versioned nor replayable.
      def creation_refusal(index)
        migration_source(index).refusal
      end

      def refuse_creation!(index)
        refuse_migration!(migration_source(index), index)
      end

      # Public: the generator reads this and migration_directory to write the migration file.
      def migration_source(index)
        MigrationSource.new(index, DocumentClass.table_name_for(index), self)
      end

      # Falls back to ActiveRecord::Base, because before the generator writes the document class
      # there is nowhere another connection could have been named.
      def migration_directory(index)
        document_class = DocumentClass.declared(index) || ActiveRecord::Base
        configured = document_class.connection_db_config.migrations_paths
        path = Array(configured).first || Rails.application.config.paths["db/migrate"].to_a.first

        Pathname.new(path.to_s.start_with?("/") ? path : Rails.root.join(path))
      end

      # There is no plan to compose: a generated migration builds the table.
      def creation_plan(index)
        raise NotImplementedError,
          "#{index.index_name} is built by migration. Run rails generate active_search:document " \
          "#{index.name}, then rails db:migrate."
      end

      def generates_document_class?
        true
      end

      # Rails already separates environments by database.
      def index_prefix
        nil
      end

      # Analysed text and filterable values live in different tables on some adapters, so every
      # requirement says which one to look in.
      def schema_requirements(index)
        locations = schema_locations(index)

        key_requirements(index, locations[:filterable]) +
          index.definition.fields.map do |field|
            Schema::Requirement.new(field: field.name, role: field.role, name: field.name,
              location: locations[field.role], native_type: expected_native_type(field))
          end
      end

      # The DDL that makes a text column searchable, which every adapter spells differently.
      def search_index_lines(table_name, text_names)
        []
      end

      # The declared fields that become ordinary columns on the document table.
      def table_fields(definition)
        definition.fields
      end

      # A collection is one JSON column whatever it holds, and a searchable field is matched against
      # the search index rather than the column.
      def expected_native_type(field)
        if field.multiple?
          collection_native_type
        elsif field.searchable?
          search_native_type
        else
          column_class(field.type, declared_width(field.type))
        end
      end

      # Rails reports an integer width in bytes and a float width in bits, and only where the
      # engine has one to report.
      def declared_width(type)
        { integer: integer_bytes, float: float_bits }[type]
      end

      def integer_bytes
        INTEGER_BYTES
      end

      # Only MySQL separates a single-precision float from a double by what it reports.
      def float_bits
        nil
      end

      def collection_native_type
        "json"
      end

      # nil skips the check: an adapter that has not said how it indexes text would otherwise fail
      # every searchable field.
      def search_native_type
        nil
      end

      # What the tables hold, in each engine's own terms. Required: inspect_schema and observe_index
      # below both call it.
      def observe_tables(index, table, connection)
        raise NotImplementedError, "#{self.class.name.demodulize} cannot report what its tables hold"
      end

      def inspect_schema(index)
        table = document_table_name(index)
        connection = document_connection(index)

        if index_present?(table, connection)
          Schema::Inspection.new(state: :found, observed: observe_tables(index, table, connection))
        else
          Schema::Inspection.new(state: :missing)
        end
      rescue ActiveRecord::ActiveRecordError => e
        Schema::Inspection.new(state: :unavailable, detail: e.message)
      end

      # The raising half of inspect_schema, which observed_schema caches.
      def observe_index(index)
        table = document_table_name(index)
        connection = document_connection(index)

        unless index_present?(table, connection)
          raise ActiveRecord::StatementInvalid, "#{table} does not exist"
        end

        observe_tables(index, table, connection)
      end

      # Also clears Active Record's column cache, which a write's upsert reads through and a live
      # observation does not. A global reset cannot name the models, so it clears them all, which
      # is cheap: reset_column_information drops memoized state and hits no database.
      def reset_schema_cache(index = nil, domain: nil)
        if index
          reset_column_information(index)
        else
          ActiveRecord::Base.descendants.each(&:reset_column_information)
        end
        super
      end

      # A connection is per index, so there is nothing to check here.
      def ping
        true
      end

      # Active Record already types the column; this pins the contract that a declared :date field
      # reads back as a Date here too.
      def type_casters
        @type_casters ||= { date: ActiveModel::Type::Date.new }
      end

      private
        # One statement instead of a delete per row.
        def delete_by_filter(index, query_context, routing: nil)
          scope = build_raw_query(index, query_context, routing: routing)
            .unscope(:limit, :offset, :select, :order)

          # Two dependent statements on SQLite: failing between them leaves meta rows whose text
          # rows are gone, and a text search and a filter would disagree from then on.
          scope.model.transaction do
            remove_fts_rows(index, scope)
            scope.delete_all
          end
        end

        def remove_fts_rows(index, scope)
          # Only SQLite keeps one.
        end

        def build_raw_query(index, query_context, routing:)
          m = model_for(index, routing: routing)
          fields_to_select = query_context.hit_fields || index.definition.field_names

          rel = ar_relation(m, query_context, index, routing: routing)
          rel = add_field_selection(rel, m, fields_to_select, query: query_context.query)
          rel = rel.limit(query_context.limit) if query_context.limit
          rel = rel.offset(query_context.offset) if query_context.offset
          rel
        end

        def execute_query(index, raw_query, query_context, routing: nil)
          total = raw_query.unscope(:limit, :offset, :select, :order).count(:all)
          records = raw_query.to_a

          fields_to_extract = query_context.hit_fields || index.definition.field_names

          results = records.map do |record|
            fields = extract_fields(record, fields_to_extract)
            highlights = extract_record_highlights(record, query_context)

            {
              id: extract_document_id(record, index),
              score: record.try(:score).to_f,
              fields: fields,
              highlights: highlights
            }
          end

          { total: total, results: results }
        end

        def extract_document_id(record, index)
          src = index.source
          values = src.storage_key_columns.each_with_object({}) do |col, h|
            h[col] = record.public_send(col) if record.respond_to?(col)
          end
          src.build_document_id(values)
        end

        def ar_relation(m, query_context, index, routing:)
          query = query_context.query
          fields = query_context.fields
          filters = query_context.all_conditions.positive
          not_filters = query_context.all_conditions.negative
          highlight_opts = query_context.highlight_opts
          sort = query_context.sort
          highlight_fields = ActiveSearch::Highlighting.fields_for(fields, highlight_opts)

          validate_search_fields!(fields, index)

          scope = if query.present?
            apply_search(m, query_context, index, routing: routing)
          else
            m.select(Arel.sql(id_select_sql(m, index)), "0 AS score")
          end

          if highlight_opts
            select_cols = highlight_select(m, query, highlight_fields, highlight_opts, schema_fields: index.definition.search_fields,
              query_context: query_context)
            scope = scope.select(select_cols.join(", ")) if select_cols.any?
          end

          scope = apply_filters(scope, filters, index.definition)
          scope = apply_not_filters(scope, not_filters, index.definition)
          apply_sort(scope, sort, query.present?)
        end

        def add_field_selection(scope, model, select_fields, query: nil)
          return scope unless select_fields.present?
          scope.select(select_fields.map { |f| "#{model.table_name}.#{f}" })
        end

        def id_select_sql(model, index)
          table = model.table_name
          index.source.storage_key_columns.map { |c| "#{table}.#{c}" }.join(", ")
        end

        # Two indexes can share an index_name while writing to different tables, so the table
        # disambiguates. The name leads, so an index-scoped reset matches every domain without
        # naming them. A domain already names its table, and a sharded index has no single one.
        def schema_observation_key(index, domain)
          [ index.index_name, domain || document_table_name(index) ]
        end

        # Which model holds this document, or answers this query. A partitioned adapter picks its
        # shard from +routing+, the same value write, delete and build_raw_query are already given.
        def model_for(index, routing: nil)
          DocumentClass.for(index)
        end

        # Any model for this index, asked only for a connection or column information. A partitioned
        # adapter answers with any shard, because they share both and no document is in scope.
        def connection_model_for(index)
          model_for(index)
        end

        def reset_column_information(index)
          connection_model_for(index).reset_column_information
        rescue DocumentClass::Absent
        end

        # Before the generator writes the document class, the name it will give the table is the
        # answer.
        def document_table_name(index)
          connection_model_for(index).table_name
        rescue DocumentClass::Absent
          DocumentClass.table_name_for(index)
        end

        def document_connection(index)
          connection_model_for(index).connection
        rescue DocumentClass::Absent
          ActiveRecord::Base.connection
        end

        def index_present?(table, connection)
          connection.table_exists?(table)
        end

        # A width only where the engine reports one, and only for numbers: a string's limit is its
        # length. MySQL FLOAT is 24-bit and DOUBLE 53-bit, and both answer :float.
        def column_class(type, bytes)
          base = COLUMN_CLASSES[type]

          SIZED_CLASSES.include?(base) && bytes ? "#{base}(#{bytes})" : base
        end

        def columns_in(connection, table, role: nil)
          connection.columns(table).map do |column|
            Schema::Observation.new(name: column.name, role: role,
              native_type: column_class(column.type, column.limit), location: table)
          end
        end

        def refuse_migration!(source, index)
          raise Schema::CreationRefused, source.refusal if source.refusal

          refuse_bad_identifiers!(source, index)

          inspection = inspect_schema(index)
          refuse_unreachable!(index, inspection)

          if inspection.found?
            raise Schema::CreationRefused,
              "Some or all of #{source.table_name} already exists. " \
              "Run verify to compare it with the declaration."
          end

          pending = pending_migration_for(index, source)
          if pending
            raise Schema::CreationRefused,
              "#{pending} is already waiting to build #{source.table_name}. Run rails db:migrate."
          end
        end

        # Postgres truncates a long identifier rather than refusing it, so the column the migration
        # builds is not the one the gem then writes to. Only the connection knows the limit: 63 on
        # Postgres and 64 on the other two.
        def refuse_bad_identifiers!(source, index)
          columns = emitted_columns(index).map(&:to_s)
          names = emitted_tables(index, source.table_name).map(&:to_s) + columns
          limit = document_connection(index).max_identifier_length
          too_long = names.select { |name| identifier_size(name) > limit }
          repeated = columns.tally.select { |_, count| count > 1 }.keys

          if too_long.any?
            raise Schema::CreationRefused,
              "#{too_long.join(", ")} is longer than this database allows (#{limit})"
          elsif repeated.any?
            raise Schema::CreationRefused,
              "#{repeated.join(", ")} would be built twice by this migration"
          end
        end

        # Postgres counts an identifier in bytes and the other two in characters, so a multibyte
        # name passes a character count and is truncated anyway.
        def identifier_size(name)
          name.length
        end

        # Listed once: an identity field is both a declared field and a storage key, and
        # MigrationSource writes it once.
        def emitted_columns(index)
          keys = index.source.respond_to?(:storage_key_columns) ? index.source.storage_key_columns : []

          [ *keys, *(index.definition.field_names - keys) ]
        end

        # Tables this adapter builds. An adapter that builds more than one overrides it.
        def emitted_tables(index, table)
          [ table ]
        end

        def pending_migration_for(index, source)
          Dir.glob(migration_directory(index).join("*_#{source.file_name}.rb"))
            .map { |path| File.basename(path) }.first
        end

        # A document is joined and de-duplicated by these, so a table without them can be neither
        # read nor written whatever its declared fields say. No type is required: the gem writes
        # strings, and a hand-built table may hold integers.
        def key_requirements(index, location)
          source = index.source
          columns = source.respond_to?(:storage_key_columns) ? source.storage_key_columns : []

          columns.map do |column|
            Schema::Requirement.new(field: column, role: :filterable, name: column, location: location)
          end
        end

        def schema_locations(index)
          table = document_table_name(index)

          { searchable: table, filterable: table }
        end

        # +routing:+ is required so an adapter picking a table or a scoping term from it cannot
        # silently ignore it. Sqlite and Postgresql take it and do nothing with it.
        def apply_search(model, query_context, index, routing:)
          raise NotImplementedError, "#{self.class} must implement apply_search"
        end

        def extract_fields(record, field_names)
          field_names.each_with_object({}) do |field, hash|
            hash[field.to_sym] = record.try(field)
          end
        end

        def highlight_select(model, query, fields, opts, schema_fields: nil, query_context:)
          []
        end

        def extract_record_highlights(record, query_context)
          return {} unless query_context.highlight_opts

          highlight_fields = ActiveSearch::Highlighting.fields_for(query_context.fields, query_context.highlight_opts)

          highlight_fields.each_with_object({}) do |field, highlights|
            fragment = ActiveSearch::Highlighting.fragment(record.try("#{field}_hl"),
              query_context.highlight_opts.for_field(field))
            highlights[field] = fragment if fragment
          end
        end

        # These names reach SQL, so they must match the declaration.
        def validate_search_fields!(fields, index)
          return if fields.blank?

          valid_fields = index.definition.search_fields.map(&:to_s)

          fields.each do |field|
            field_name = field.to_s
            unless valid_fields.include?(field_name)
              raise QueryError, "Invalid search field: #{field_name.inspect}. Valid fields: #{valid_fields.join(', ')}"
            end
          end
        end
    end
  end
end
