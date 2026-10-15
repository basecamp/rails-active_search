module ActiveSearch
  module StoreAdapters
    # Store adapter for Microsoft SQL Server Full-Text Search, selected with
    # <tt>adapter: sqlserver</tt>.
    #
    # Searches the application database through Active Record. SQL Server requires one unique,
    # non-null key index for each full-text index; generated migrations create a dedicated index on
    # the document table's primary key and use CONTAINSTABLE to return native relevance ranks.
    class Sqlserver < Database
      extend ActiveSupport::Autoload

      eager_autoload do
        autoload :QueryBuilding
      end

      include QueryBuilding

      CATALOG_NAME = "active_search".freeze

      def migration_preamble_lines
        [ "  disable_ddl_transaction!", "" ]
      end

      def search_index_lines(table_name, text_names)
        key_index = fulltext_key_index_name(table_name)
        columns = text_names.map { |name| "[#{name}] LANGUAGE 1033" }.join(", ")

        [
          "",
          "    add_index :#{table_name}, :id, unique: true, name: :#{key_index}",
          "",
          "    reversible do |direction|",
          "      direction.up do",
          "        execute \"IF FULLTEXTSERVICEPROPERTY('IsFullTextInstalled') <> 1 THROW 50000, 'SQL Server Full-Text Search is not installed', 1\"",
          "        execute \"IF NOT EXISTS (SELECT 1 FROM sys.fulltext_catalogs WHERE name = '#{CATALOG_NAME}') CREATE FULLTEXT CATALOG [#{CATALOG_NAME}]\"",
          "        execute \"CREATE FULLTEXT INDEX ON [#{table_name}] (#{columns}) KEY INDEX [#{key_index}] ON [#{CATALOG_NAME}] WITH CHANGE_TRACKING AUTO\"",
          "      end",
          "      direction.down do",
          "        execute \"DROP FULLTEXT INDEX ON [#{table_name}]\"",
          "      end",
          "    end"
        ]
      end

      def search_native_type
        "fulltext"
      end

      # SQL Server stores Rails JSON columns as nvarchar(max), which Active Record reports as a
      # string column even though OPENJSON provides collection semantics when querying it.
      def expected_native_type(field)
        field.multiple? ? "string" : super
      end

      def observe_tables(index, table, connection)
        searchable = connection.select_values(<<~SQL.squish)
          SELECT columns.name
          FROM sys.fulltext_index_columns AS fulltext_columns
          INNER JOIN sys.columns AS columns
            ON columns.object_id = fulltext_columns.object_id
           AND columns.column_id = fulltext_columns.column_id
          WHERE fulltext_columns.object_id = OBJECT_ID(#{connection.quote(table)})
        SQL

        columns_in(connection, table, role: :filterable) + searchable.map do |name|
          Schema::Observation.new(name: name, role: :searchable, native_type: "fulltext", location: table)
        end
      end

      def write(index, document, routing: nil)
        key = index.source.storage_key(document.id)
        columns = document.writable_field_names - key.keys
        model = model_for(index, routing: routing)

        model.transaction(requires_new: true) do
          model.upsert(key.merge(replacement_attributes(document, columns)))
        end
      end

      def replacement_attributes(document, names)
        super.transform_values do |value|
          value.is_a?(Array) ? ActiveSupport::JSON.encode(value) : value
        end
      end

      def execute_query(index, raw_query, query_context, routing: nil)
        super.tap do |response|
          collection_names = index.definition.fields.select(&:multiple?).map(&:name)
          response[:results].each do |result|
            collection_names.each do |name|
              value = result[:fields][name]
              result[:fields][name] = ActiveSupport::JSON.decode(value) if value.is_a?(String)
            end
          end
        end
      end

      def type_casters
        @type_casters ||= super.merge(datetime: ActiveModel::Type::DateTime.new)
      end

      def refresh(index_name)
        models_for_store_name(index_name).each do |model|
          wait_for_population(model.connection, model.table_name)
        end
      end

      def capabilities
        @capabilities ||= Capabilities.new(
          index_creation: true,
          collection_ranges: true,
          highlighting: false,
          highlight_snippet_units: [],
          highlight_per_field_markers: false,
          highlight_per_field_snippets: false,
          operator: false,
          max_result_window: options.fetch(:max_result_window, 10_000)
        )
      end

      private
        def wait_for_population(connection, table_name)
          object_id = connection.select_value("SELECT OBJECT_ID(#{connection.quote(table_name)})").to_i
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + options.fetch(:population_timeout, 120)
          loop do
            pending_changes, population_status, population = connection.uncached do
              [
                connection.select_value(
                  "SELECT OBJECTPROPERTYEX(#{object_id}, 'TableFulltextPendingChanges')"
                ).to_i,
                connection.select_value(
                  "SELECT OBJECTPROPERTYEX(#{object_id}, 'TableFulltextPopulateStatus')"
                ).to_i,
                connection.select_one(<<~SQL.squish)
                  SELECT has_crawl_completed
                  FROM sys.fulltext_indexes
                  WHERE object_id = #{object_id}
                SQL
              ]
            end
            crawl_completed = [ true, 1 ].include?(population.fetch("has_crawl_completed"))
            break if pending_changes.zero? && crawl_completed && population_status.zero?

            if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
              raise ActiveRecord::StatementTimeout,
                "SQL Server full-text population timed out for #{table_name} " \
                  "(pending changes: #{pending_changes}, population status: #{population_status})"
            end

            sleep 0.05
          end
        end

        def models_for_store_name(index_name)
          indexes = ActiveSearch.index_names.filter_map do |name|
            index = ActiveSearch.index(name)
            next unless index.index_name == index_name.to_sym

            index if index.store.equal?(self)
          rescue ConfigurationError
            nil
          end
          if indexes.empty?
            raise ConfigurationError, "No index on this store uses the name :#{index_name}"
          end

          indexes.map { |index| connection_model_for(index) }
            .uniq { |model| [ model.connection.object_id, model.table_name ] }
        end

        def fulltext_key_index_name(table_name)
          "index_#{table_name}_on_id_for_fulltext"
        end
    end
  end
end
