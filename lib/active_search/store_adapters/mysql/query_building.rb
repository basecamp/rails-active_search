module ActiveSearch
  module StoreAdapters
    class Mysql
      module QueryBuilding # :nodoc: all
        private
          # JSON_OVERLAPS is true when two documents share any element; MySQL 8.0.17 and later.
          def collection_overlap_sql(scope, column, values)
            return "1 = 0" if values.empty?

            scope.model.sanitize_sql_array([ "JSON_OVERLAPS(#{column}, CAST(? AS JSON))", values.to_json ])
          end

          # connection.quote wraps the fully composed query, so an adapter's own operators land
          # inside the literal and cannot widen the statement.
          def apply_search(model, query_context, index, routing:)
            columns = quoted_match_columns(match_columns(index, query_context), model, index)
            escaped = model.connection.quote(boolean_query(query_context, routing: routing))
            match_expr = "MATCH(#{columns.join(', ')}) AGAINST(#{escaped} IN BOOLEAN MODE)"

            model
              .select(Arel.sql(id_select_sql(model, index)), "#{match_expr} AS score")
              .where(Arel.sql(match_expr))
          end

          # The columns MATCH names. MySQL matches a FULLTEXT index by its whole column list, so an
          # adapter whose index carries a scoping column alongside the text ones overrides this.
          def match_columns(index, query_context)
            query_context.fields
          end

          # The boolean-mode query. sanitize_boolean_query covers the user's terms and nothing
          # else, so an adapter adding a routing term wraps this result rather than the raw query.
          def boolean_query(query_context, routing: nil)
            sanitize_boolean_query(query_context.query.to_s)
          end

          # One value as a required phrase, a list as a required group: the safe way for an adapter
          # to put a routing value into the query. A quote inside would end the phrase and unrequire
          # the term, and a blank term makes the whole operator a no-op — either way the routing
          # stops scoping anything, so quotes go and a blank raises.
          def boolean_term(value, operator: "+")
            terms = Array(value).map { |v| v.to_s.delete('"') }

            if terms.empty? || terms.any?(&:blank?)
              raise QueryError, "A boolean-mode term cannot be blank: #{value.inspect} would match every document"
            end

            terms.one? ? %(#{operator}"#{terms.first}") : "#{operator}(#{terms.map { |t| %("#{t}") }.join(' ')})"
          end

          # An adapter may name a physical column the gem never sees, so the names cannot be checked
          # against the declaration and quoting is what closes the interpolation.
          def quoted_match_columns(columns, model, index)
            names = Array(columns).map(&:to_s)

            # Diagnostic, not security: MySQL's own error for MATCH() sends the author elsewhere. A
            # blank element quotes to ``, so a non-empty list is not the same as one naming a column.
            if names.empty?
              raise QueryError, "match_columns named no columns for :#{index.name}, so there is nothing to MATCH"
            elsif names.any?(&:blank?)
              raise QueryError, "match_columns named a blank column for :#{index.name}: #{Array(columns).inspect}"
            end

            names.map { |name| model.connection.quote_column_name(name) }
          end

          BOOLEAN_BAREWORD = /\A\w+\z/
          BOOLEAN_STANDALONE_OPERATORS = /\A[+\-<>~*@()"]+\z/

          # capabilities declare operator: false, so boolean-mode syntax from user input must read as
          # literal terms. connection.quote above stops SQL injection only; the engine still parses
          # the string, and a bare @ or an unbalanced " is ER 1064.
          #
          # Runs on the user's terms alone. An adapter that changes the query overrides
          # boolean_query, never this.
          def sanitize_boolean_query(query)
            result = []
            remaining = query.dup

            while remaining.present?
              if (phrase = remaining.match(/\A"([^"]*)"/))
                result << "\"#{phrase[1]}\""
                remaining = phrase.post_match
              elsif (word = remaining.match(/\A(\S+)/))
                term = word[1].delete('"')
                remaining = word.post_match

                unless term.empty? || term.match?(BOOLEAN_STANDALONE_OPERATORS)
                  result << (term.match?(BOOLEAN_BAREWORD) ? term : "\"#{term}\"")
                end
              else
                remaining = remaining.lstrip
              end
            end

            result.join(" ")
          end
      end
    end
  end
end
