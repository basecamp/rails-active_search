module ActiveSearch
  module StoreAdapters
    class Sqlite
      module ResponseParsing # :nodoc: all
        private
          # Private like Database's, which this overrides: nothing outside the adapter calls it.
          def add_field_selection(scope, model, select_fields, query: nil)
            return scope unless select_fields.present?

            table = model.table_name
            fts_table = "#{table}_fts"
            meta_columns, fts_columns = table_columns(model.connection, table, fts_table)

            # Text lives in the FTS table, which only a search joins — joined here for a filter-only
            # query, or every text field asked for silently reads back nil. LEFT, so a document
            # whose FTS row is missing still answers its filters.
            if query.blank? && select_fields.any? { |field| fts_columns.include?(field.to_s) }
              scope = scope.joins("LEFT JOIN #{fts_table} ON #{fts_table}.rowid = #{table}.rowid")
            end

            select_fields.each do |field|
              field_str = field.to_s
              in_meta = meta_columns.include?(field_str)
              in_fts = fts_columns.include?(field_str)

              # The FTS table wins where a name is in both, because that is where the text is.
              if in_fts
                scope = scope.select("#{fts_table}.#{field}")
              elsif in_meta
                scope = scope.select("#{table}.#{field}")
              end
            end
            scope
          end

          # Keyed by connection too: two databases can hold same-named tables with different columns.
          def table_columns(connection, meta_table, fts_table)
            @table_columns_cache ||= {}
            @table_columns_cache[[ connection, meta_table, fts_table ]] ||= begin
              meta_cols = connection.columns(meta_table).map(&:name) - %w[id rowid]
              fts_cols = fts_column_names(connection, fts_table)
              [ meta_cols, fts_cols ]
            end
          end

          # PRAGMA rather than connection.columns, which does not introspect a virtual table.
          def fts_column_names(connection, fts_table)
            result = connection.execute("PRAGMA table_info(#{fts_table})")
            result.map { |row| row["name"] }
          end
      end
    end
  end
end
