module ActiveSearch
  module StoreAdapters
    class Sqlite
      module Highlighting # :nodoc: all
        private
          def highlight_select(model, query, fields, opts, schema_fields: nil, query_context:)
            # No query matches nothing and joins no FTS table, so highlight() would error against
            # an unjoined table. Nothing to mark is an empty select, not an error.
            return [] if query.blank?

            conn = model.connection
            fts_table = "#{model.table_name}_fts"
            # highlight() counts the FTS table's physical columns, and a hand-built table need not
            # share the declaration's order — so the ordinal comes from the table, not the schema.
            # Through the memo, or every highlighted search would run the PRAGMA again.
            _, columns = table_columns(conn, model.table_name, fts_table)

            fields.map do |field|
              idx = columns.index(field.to_s)

              unless idx
                raise QueryError,
                  "Cannot highlight '#{field}' because #{fts_table} has no such column: #{columns.join(', ')}"
              end

              field_opts = opts.for_field(field)
              open_marker = conn.quote(ActiveSearch::Highlighting::STORE_OPEN_MARKER)
              close_marker = conn.quote(ActiveSearch::Highlighting::STORE_CLOSE_MARKER)
              highlight_alias = conn.quote_column_name("#{field}_hl")

              if field_opts.snippet?
                words = snippet_words_for(field_opts)
                ellipsis = conn.quote(ActiveSearch::Highlighting::SNIPPET_ELLIPSIS)
                "snippet(#{fts_table}, #{idx}, #{open_marker}, #{close_marker}, #{ellipsis}, #{words}) AS #{highlight_alias}"
              else
                "highlight(#{fts_table}, #{idx}, #{open_marker}, #{close_marker}) AS #{highlight_alias}"
              end
            end
          end
      end
    end
  end
end
