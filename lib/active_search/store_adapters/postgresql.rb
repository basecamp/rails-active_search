module ActiveSearch
  module StoreAdapters
    # Store adapter for PostgreSQL full-text search, selected with <tt>adapter: postgresql</tt>.
    #
    # Searches the application database through Active Record, so it takes no connection options.
    #
    # Every searchable field needs a <tt><name>_vector</tt> tsvector column beside its raw one: the
    # query matches the vector and the read selects the column. The generated migration adds both,
    # and a write fills both.
    class Postgresql < Database
      # :stopdoc:
      extend ActiveSupport::Autoload

      eager_autoload do
        autoload :QueryBuilding
        autoload :Highlighting
      end

      include QueryBuilding, Highlighting

      # A column is filterable. It is searchable only where its tsvector companion exists, since
      # that is the column a query matches against.
      def search_index_lines(table_name, text_names)
        [ "" ] + text_names.flat_map do |name|
          [ "    add_column :#{table_name}, :#{name}_vector, :tsvector",
            "    add_index :#{table_name}, :#{name}_vector, using: :gin" ]
        end
      end

      # A tsvector column records that it is a tsvector and not which configuration built it, so a
      # column filled with to_tsvector('simple') verifies against one this adapter wrote with 'english'.
      def search_native_type
        "tsvector"
      end

      def identifier_size(name)
        name.bytesize
      end

      def emitted_columns(index)
        super + index.definition.search_fields.map { |name| "#{name}_vector" }
      end

      def collection_native_type
        "jsonb"
      end

      def observe_tables(index, table, connection)
        columns = connection.columns(table)
        names = columns.map(&:name)
        # Both halves: a read selects the raw column and a write inserts into it, so a vector
        # without one says nothing about where the text is kept.
        vectors = columns.select { |column| column.sql_type == "tsvector" && column.name.end_with?("_vector") }
          .map { |column| column.name.delete_suffix("_vector") }
          .select { |name| names.include?(name) }

        columns_in(connection, table, role: :filterable) +
          vectors.map do |name|
            Schema::Observation.new(name: name, role: :searchable, native_type: "tsvector", location: table)
          end
      end

      def write(index, document, routing: nil)
        m = model_for(index, routing: routing)
        conn = m.connection
        definition = document.definition

        field_names = document.search_fields

        key = index.source.storage_key(document.id)
        id_names = key.keys
        id_values = key.values.map { |v| conn.quote(v) }
        conflict_columns = "(#{id_names.join(', ')})"

        vector_columns = field_names.map { |c| "#{c}_vector" }
        # The same rule as the other two, spelled into SQL because a tsvector is an expression
        # Active Record's upsert will not take.
        filters = replacement_attributes(document, document.filter_field_names - id_names - field_names)
        filter_names = filters.keys

        all_columns = (id_names + field_names + filter_names).map(&:to_s) + vector_columns
        # An absent text field is NULL in the raw column, like MySQL's. The vector keeps "": a NULL
        # tsvector nullifies every vector_a || vector_b it joins, hiding the document's other fields.
        field_values = field_names.map { |f| conn.quote(document.data[f]&.to_s) }
        filter_values = filters.map { |name, value| quote_filter_value(conn, definition[name], value) }
        vector_values = field_names.map { |f| "to_tsvector('english', #{conn.quote(document.data[f].to_s)})" }

        all_values = id_values + field_values + filter_values + vector_values
        update_parts = (field_names.map(&:to_s) + filter_names.map(&:to_s) + vector_columns).map { |c| "#{c} = EXCLUDED.#{c}" }

        # Narrowing can leave nothing but the key, and DO UPDATE SET needs at least one assignment.
        on_conflict = update_parts.any? ? "DO UPDATE SET #{update_parts.join(', ')}" : "DO NOTHING"

        conn.execute(<<~SQL)
          INSERT INTO #{m.table_name} (#{all_columns.join(', ')}) VALUES (#{all_values.join(', ')})
          ON CONFLICT #{conflict_columns} #{on_conflict}
        SQL
      end

      def capabilities
        @capabilities ||= Capabilities.new(
          # By writing a migration, which is how a table in the application's own schema is built.
          index_creation: true,
          # A range over a collection: one EXISTS over jsonb_array_elements carries both bounds.
          collection_ranges: true,
          highlight_snippet_units: [ :words ],
          operator: false,
          # Nothing caps a database page: the store returns and materializes whatever LIMIT asks.
          max_result_window: options.fetch(:max_result_window, 10_000)
        )
      end

      private
        # This adapter writes its own SQL, so a value never passes through the column's Active Record
        # type and a collection reaches quote as an Array. Encoded here instead, as the json type
        # would have done on the way in.
        def quote_filter_value(conn, field, value)
          if field&.multiple? && !value.nil?
            "#{conn.quote(value.to_json)}::jsonb"
          else
            conn.quote(value)
          end
        end
    end
  end
end
