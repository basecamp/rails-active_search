module ActiveSearch
  module StoreAdapters
    class Postgresql
      module Highlighting # :nodoc: all
        private
          def highlight_select(model, query, fields, opts, schema_fields: nil, query_context:)
            conn = model.connection

            tsquery = build_tsquery(model, query_context)

            fields.map do |field|
              field_opts = opts.for_field(field)
              column = conn.quote_column_name(field)
              headline_alias = conn.quote_column_name("#{field}_hl")

              "ts_headline('english', #{column}, #{tsquery}, #{conn.quote(headline_options(field_opts))}) AS #{headline_alias}"
            end
          end

          def headline_options(field_opts)
            start_sel = escape_headline_marker(ActiveSearch::Highlighting::STORE_OPEN_MARKER)
            stop_sel = escape_headline_marker(ActiveSearch::Highlighting::STORE_CLOSE_MARKER)

            if field_opts.snippet?
              words = snippet_words_for(field_opts)
              # MinWords must be under MaxWords, so an exact count of n goes as n and n + 1.
              "StartSel=\"#{start_sel}\", StopSel=\"#{stop_sel}\", MaxWords=#{words + 1}, MinWords=#{words}"
            else
              # HighlightAll returns the whole field with every match marked.
              "StartSel=\"#{start_sel}\", StopSel=\"#{stop_sel}\", HighlightAll=true"
            end
          end

          # PostgreSQL escapes a quote inside a headline option by doubling it.
          def escape_headline_marker(marker)
            marker.gsub('"', '""')
          end
      end
    end
  end
end
