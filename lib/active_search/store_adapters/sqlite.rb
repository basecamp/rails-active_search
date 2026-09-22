module ActiveSearch
  module StoreAdapters
    # Store adapter for SQLite FTS5, selected with <tt>adapter: sqlite</tt>.
    #
    # Searches the application database through Active Record, so it takes no connection options.
    # The generated migration builds two tables: the document table holds the filter columns, and
    # <tt><table>_fts</tt> holds the text.
    #
    # A searchable field has no column on the document table, so only the FTS table can answer it.
    class Sqlite < Database
      # :stopdoc:
      extend ActiveSupport::Autoload

      eager_autoload do
        autoload :QueryBuilding
        autoload :ResponseParsing
        autoload :Highlighting
      end

      include QueryBuilding, ResponseParsing, Highlighting

      # Neither obvious ActiveRecord call works on an FTS5 table. table_exists? answers false for
      # one, because virtual tables are filtered out of the list, and columns returns four names
      # rather than two -- FTS5 adds a hidden column named after the table, and rank.
      def observe_tables(index, table, connection)
        fts = "#{table}_fts"
        meta = connection.table_exists?(table) ? columns_in(connection, table, role: :filterable) : []

        text = virtual_table?(connection, fts) ? fts_columns(connection, fts).map { |name|
          Schema::Observation.new(name: name, role: :searchable, native_type: "fts5", location: fts)
        } : []

        meta + text
      end

      # A name is not enough: an ordinary table called article_documents_fts would be read as FTS5
      # and then verify compatible, while MATCH against it fails.
      def virtual_table?(connection, table) # :nodoc:
        sql = connection.select_value(sanitize_sql(ActiveRecord::Base,
          [ "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?", table ]))

        sql.to_s.match?(/CREATE\s+VIRTUAL\s+TABLE.*USING\s+fts5/i)
      end

      def fts_columns(connection, table) # :nodoc:
        connection.select_values(sanitize_sql(ActiveRecord::Base,
          [ "SELECT name FROM pragma_table_info(?)", table ]))
      end

      def search_index_lines(table_name, text_names)
        [ "\n    create_virtual_table :#{table_name}_fts, :fts5, #{text_names.inspect}" ]
      end

      def schema_locations(index)
        table = document_table_name(index)
        { searchable: "#{table}_fts", filterable: table }
      end

      def emitted_tables(index, table)
        super + [ "#{table}_fts" ]
      end

      # write puts only filter columns on the document table, so a column for a text field would
      # always be NULL.
      def table_fields(definition)
        definition.fields.reject(&:searchable?)
      end

      def search_native_type
        "fts5"
      end

      # SQLite's INTEGER widens on its own, so there is no narrower column to catch.
      def integer_bytes
        nil
      end

      def write(index, document, routing: nil)
        m = model_for(index, routing: routing)
        fts_table = "#{m.table_name}_fts"

        data = document.data
        text_fields = document.search_fields
        key = index.source.storage_key(document.id)

        # Only filter columns live in the meta table; the text goes to the FTS table below.
        columns = document.filter_field_names - key.keys

        # One transaction, or a meta row can outlive a failed FTS write and a filter would find a
        # document a text search cannot.
        m.transaction do
          m.upsert(key.merge(replacement_attributes(document, columns)), unique_by: key.keys)
          write_fts_row(m, fts_table, m.where(key).pick(:rowid), text_fields, data)
        end
      end

      # Skipped when narrowing leaves no searchable field, since the column list would be empty.
      def write_fts_row(model, fts_table, rowid, text_fields, data) # :nodoc:
        return if text_fields.empty?

        field_names = text_fields.map(&:to_s)
        # NULL for an absent field, like the other database adapters: FTS5 stores it, and matching
        # and snippet() over the column are unaffected.
        field_values = text_fields.map { |f| data[f]&.to_s }
        placeholders = ([ "?" ] * (field_names.size + 1)).join(", ")

        model.connection.execute(sanitize_sql(model, [
          "INSERT OR REPLACE INTO #{fts_table} (rowid, #{field_names.join(', ')}) VALUES (#{placeholders})",
          rowid, *field_values
        ]))
      end

      def delete(index, id, routing: nil)
        m = model_for(index, routing: routing)
        fts_table = "#{m.table_name}_fts"
        key = index.source.storage_key(id)

        # One transaction, like write: a crash between the two deletes would leave a meta row a
        # filter finds and a text search cannot. FTS first, because its rowid comes from the meta row.
        m.transaction do
          rowid = m.where(key).pick(:rowid)

          if rowid
            m.connection.execute(sanitize_sql(m, [
              "DELETE FROM #{fts_table} WHERE rowid = ?",
              rowid
            ]))
          end

          super
        end
      end

      # The read side's column cache follows the observation cache: a reset that lets the schema
      # be re-observed must also let field selection stop serving the old column list.
      def reset_schema_cache(index = nil, domain: nil)
        @table_columns_cache = nil
        super
      end

      def capabilities
        @capabilities ||= Capabilities.new(
          # By writing a migration, which is how a table in the application's own schema is built.
          index_creation: true,
          # A range over a collection: one EXISTS over json_each carries both bounds.
          collection_ranges: true,
          highlight_snippet_units: [ :words ],
          operator: false,
          # Nothing caps a database page: the store returns and materializes whatever LIMIT asks.
          max_result_window: options.fetch(:max_result_window, 10_000)
        )
      end

      private
        # Either half is enough to say something is there. Reporting missing because only the FTS
        # table exists would have a migration written that then collides with it.
        def index_present?(table, connection)
          connection.table_exists?(table) || virtual_table?(connection, "#{table}_fts")
        end

        # The FTS rows go first, because their rowids come from the meta table. Skip this and the
        # FTS table keeps an orphan per deleted document: search stays correct, since the read path
        # joins the meta table, but nothing ever prunes them.
        def remove_fts_rows(index, scope)
          # From the scope, not model_for: the caller resolved the routing and no routing reaches here.
          model = scope.model
          # Qualified: a filter-only scope selecting text fields joins the FTS table, where a bare
          # rowid is ambiguous.
          rowids = scope.pluck(Arel.sql("#{model.table_name}.rowid"))
          return if rowids.empty?

          model.connection.execute(sanitize_sql(model, [
            "DELETE FROM #{model.table_name}_fts WHERE rowid IN (?)", rowids
          ]))
        end

        def sanitize_sql(model, sql_array)
          model.sanitize_sql_array(sql_array)
        end
    end
  end
end
