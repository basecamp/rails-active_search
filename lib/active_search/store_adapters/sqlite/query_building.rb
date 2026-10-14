module ActiveSearch
  module StoreAdapters
    class Sqlite
      module QueryBuilding # :nodoc: all
        private
          # json_each already unrolls the collection into rows, so a range is an ordinary comparison
          # over them. json_each.value comes back typed, so no cast is needed either way.
          def collection_range_sql(scope, column, range, numeric)
            low, high, exclusive = range_bounds(range)
            tests = []
            tests << scope.model.sanitize_sql_array([ "json_each.value >= ?", low ]) unless low.nil?
            tests << scope.model.sanitize_sql_array([ "json_each.value #{exclusive ? '<' : '<='} ?", high ]) unless high.nil?
            return "1 = 1" if tests.empty?

            "EXISTS (SELECT 1 FROM json_each(#{column}) WHERE #{tests.join(' AND ')})"
          end

          # json_each unrolls the stored collection into rows, so overlap is an ordinary IN over
          # them. FTS5 holds only the text fields, so a collection column stays in the meta table.
          def collection_overlap_sql(scope, column, values)
            return "1 = 0" if values.empty?

            placeholders = ([ "?" ] * values.size).join(", ")
            scope.model.sanitize_sql_array([
              "EXISTS (SELECT 1 FROM json_each(#{column}) WHERE json_each.value IN (#{placeholders}))",
              *values
            ])
          end

          def apply_search(model, query_context, index, routing:)
            table = model.table_name
            fts_table = "#{table}_fts"
            fts_query = build_fts_query(query_context)
            # A query of only operators sanitizes to nothing, and FTS5 refuses an empty MATCH.
            match = fts_query ? "#{fts_table}.#{fts_table} MATCH #{model.connection.quote(fts_query)}" : "1 = 0"

            model
              .select(Arel.sql(id_select_sql(model, index)), "#{fts_table}.rank AS score")
              .joins("INNER JOIN #{fts_table} ON #{fts_table}.rowid = #{table}.rowid")
              .where(Arel.sql(match))
          end

          def build_fts_query(query_context)
            query = query_context.query
            fields = query_context.fields

            sanitized = sanitize_fts_query(query)
            return if sanitized.empty?

            # FTS5 column filter syntax: {col1 col2} : query. Parenthesized, since the filter
            # otherwise binds only to the first phrase and later terms match every column.
            field_list = fields.map(&:to_s).join(" ")
            "{#{field_list}} : (#{sanitized})"
          end

          FTS5_BAREWORD = /\A\w+\z/
          FTS5_STANDALONE_OPERATORS = /\A[|+\-*^]+\z/
          # Barewords FTS5 reads as operators. Case-sensitive, as FTS5 is: "or" is a plain word.
          FTS5_KEYWORDS = %w[ AND OR NOT ].freeze

          # Quotes anything that is not a plain bareword, so every FTS5-significant character (C++,
          # test@example.com, an unbalanced ") reads as literal text rather than syntax. Listing the
          # significant characters is a treadmill: FTS5 rejects any bare punctuation, not a set.
          #
          # Match objects, not $~: quoting a term calls gsub, which resets the global match state.
          def sanitize_fts_query(query)
            result = []
            remaining = query.dup

            while remaining.present?
              if (phrase = remaining.match(/\A"([^"]*)"/))
                result << "\"#{phrase[1]}\""
                remaining = phrase.post_match
              elsif (word = remaining.match(/\A(\S+)/))
                term = word[1]
                remaining = word.post_match

                unless term.match?(FTS5_STANDALONE_OPERATORS)
                  bareword = term.match?(FTS5_BAREWORD) && !FTS5_KEYWORDS.include?(term)
                  result << (bareword ? term : "\"#{term.gsub('"', '""')}\"")
                end
              else
                remaining = remaining.lstrip
              end
            end

            result.join(" ")
          end

          # Ascending, where the other database adapters sort DESC: "score" here aliases fts.rank,
          # which FTS5 makes more negative for a better match. DESC would return the worst match
          # first, and every count-based test would stay green.
          def score_order
            "score"
          end
      end
    end
  end
end
