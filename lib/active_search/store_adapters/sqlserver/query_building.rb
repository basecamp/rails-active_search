module ActiveSearch
  module StoreAdapters
    class Sqlserver
      module QueryBuilding # :nodoc: all
        private
          def collection_overlap_sql(scope, column, values)
            return "1 = 0" if values.empty?

            placeholders = ([ "?" ] * values.size).join(", ")
            scope.model.sanitize_sql_array([
              "EXISTS (SELECT 1 FROM OPENJSON(#{column}) WHERE [value] IN (#{placeholders}))",
              *values.map(&:to_s)
            ])
          end

          def collection_range_sql(scope, column, range, numeric)
            low, high, exclusive = range_bounds(range)
            value = numeric ? "TRY_CONVERT(bigint, [value])" : "[value]"
            tests = []
            tests << scope.model.sanitize_sql_array([ "#{value} >= ?", low ]) unless low.nil?
            tests << scope.model.sanitize_sql_array([ "#{value} #{exclusive ? '<' : '<='} ?", high ]) unless high.nil?
            return "1 = 1" if tests.empty?

            "EXISTS (SELECT 1 FROM OPENJSON(#{column}) WHERE #{tests.join(' AND ')})"
          end

          def apply_search(model, query_context, index, routing:)
            connection = model.connection
            table = connection.quote_table_name(model.table_name)
            columns = query_context.fields.map { |field| connection.quote_column_name(field) }
            column_list = columns.one? ? columns.first : "(#{columns.join(', ')})"
            sanitized_query = sanitize_contains_query(query_context.query.to_s,
              stopwords: fulltext_stopwords(connection))
            return model.none.select(Arel.sql(id_select_sql(model, index)), "0 AS score") if sanitized_query.blank?

            search = connection.quote(sanitized_query)
            fulltext = "CONTAINSTABLE(#{table}, #{column_list}, #{search}) AS [active_search_fts]"
            primary_key = connection.quote_column_name(model.primary_key)

            model
              .select(Arel.sql(id_select_sql(model, index)), "[active_search_fts].[RANK] AS score")
              .joins("INNER JOIN #{fulltext} ON #{table}.#{primary_key} = [active_search_fts].[KEY]")
          end

          # SQL Server has no boolean scalar type, so COALESCE(predicate, false) is invalid SQL.
          # CASE preserves Active Search's rule that a rejected predicate which evaluates to NULL
          # is treated as false and therefore keeps the document.
          def apply_not_filter(scope, field, value)
            ast = scope.klass.all.where(field => value).where_clause.ast
            apply_nullable_negation(scope, ast)
          end

          def apply_not_group(scope, group, definition)
            branches = group.branches.map do |branch|
              branch.reduce(scope.klass.all) { |s, condition| apply_positive(s, condition, definition) }
            end

            apply_nullable_negation(scope, branches.reduce { |a, b| a.or(b) }.where_clause.ast)
          end

          # Active Search does not expose SQL Server's full CONTAINS grammar. Quoting each plain
          # term keeps operators and punctuation as data, while preserving a balanced user phrase.
          def sanitize_contains_query(query, stopwords: {})
            terms = []
            remaining = query.dup

            while remaining.present?
              if (phrase = remaining.match(/\A"([^"]*)"/))
                terms << quote_contains_term(phrase[1]) unless phrase[1].blank?
                remaining = phrase.post_match
              elsif (word = remaining.match(/\A(\S+)/))
                term = word[1].delete('"').sub(/\A[+\-~<>]+/, "")
                terms << quote_contains_term(term) unless term.blank? || stopwords.key?(term.downcase)
                remaining = word.post_match
              else
                remaining = remaining.lstrip
              end
            end

            terms.join(" AND ")
          end

          def fulltext_stopwords(connection)
            @fulltext_stopwords ||= connection.select_values(<<~SQL.squish).index_with(true)
              SELECT stopword
              FROM sys.fulltext_system_stopwords
              WHERE language_id = 1033
            SQL
          end

          def quote_contains_term(term)
            %("#{term.gsub('"', '""')}")
          end

          def apply_nullable_negation(scope, predicate)
            expression = Arel::Nodes::Case.new
              .when(predicate).then(Arel::Nodes.build_quoted(1))
              .else(Arel::Nodes.build_quoted(0))

            scope.where(expression.eq(0))
          end
      end
    end
  end
end
