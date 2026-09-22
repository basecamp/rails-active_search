module ActiveSearch
  module StoreAdapters
    class Database
      module QueryBuilding # :nodoc: all
        private
          # The definition comes along because a collection column is filtered by containment rather
          # than equality, and only the definition says which columns are collections.
          def apply_filters(scope, filters, definition)
            return scope if filters.blank?

            filters.each do |condition|
              scope = if condition.is_a?(ActiveSearch::Conditions::Group)
                apply_group(scope, condition, definition)
              else
                apply_positive(scope, condition, definition)
              end
            end
            scope
          end

          def apply_positive(scope, condition, definition)
            if collection_field?(definition, condition.field)
              scope.where(Arel.sql(collection_predicate(scope, condition, definition[condition.field])))
            else
              apply_filter(scope, condition.field, filter_value_for(condition))
            end
          end

          # Branches are built against the bare model so they differ only in their where clauses,
          # which is what ActiveRecord's #or requires. Only that clause is merged back.
          def apply_group(scope, group, definition)
            return scope.where(scope.klass.primary_key => []) if group.branches.empty?

            branches = group.branches.map do |branch|
              branch.reduce(scope.klass.all) { |s, condition| apply_positive(s, condition, definition) }
            end

            scope.where(branches.reduce { |a, b| a.or(b) }.where_clause.ast)
          end

          def apply_not_filters(scope, not_filters, definition)
            return scope if not_filters.blank?

            not_filters.each do |condition|
              scope = if condition.is_a?(ActiveSearch::Conditions::Group)
                apply_not_group(scope, condition, definition)
              elsif collection_field?(definition, condition.field)
                scope.where.not(Arel.sql(collection_predicate(scope, condition, definition[condition.field])))
              else
                apply_not_filter(scope, condition.field, filter_value_for(condition))
              end
            end
            scope
          end

          # COALESCE, because SQL answers UNKNOWN where a compared column is NULL and negating that
          # is UNKNOWN again, so a row filter never kept would not be rejected either.
          def apply_not_group(scope, group, definition)
            branches = group.branches.map do |branch|
              branch.reduce(scope.klass.all) { |s, condition| apply_positive(s, condition, definition) }
            end

            ast = branches.reduce { |a, b| a.or(b) }.where_clause.ast
            scope.where.not(Arel::Nodes::NamedFunction.new("COALESCE", [ ast, Arel::Nodes.build_quoted(false) ]))
          end

          def collection_field?(definition, field)
            definition[field]&.multiple?
          end

          # A JSON element compares as a number or as text, and only the field says which. A datetime
          # is stored as its ISO string, which orders correctly as text.
          def numeric_collection?(field)
            field&.type == :integer
          end

          # Overlap: the collection holds any of the named values, where a single-value column
          # compares its one value, so the same filter(f: [ 1, 2 ]) is IN there and overlap here.
          # An empty collection is stored, so a missing filter asks for NULL and does not find one.
          def collection_predicate(scope, condition, definition_field = nil)
            table = scope.model.table_name
            column = "#{scope.model.connection.quote_table_name(table)}.#{scope.model.connection.quote_column_name(condition.field)}"

            # Array.wrap rather than Array(): Array() calls to_a on anything that answers it, and
            # Time#to_a is ten fields rather than one value. as_json because the column encoded the
            # document the same way, so a bare Time would never equal the ISO string stored.
            values = Array.wrap(condition.value).map(&:as_json)

            if condition.value.is_a?(::Range)
              collection_range_sql(scope, column, condition.value, numeric_collection?(definition_field))
            elsif condition.missing_only?
              "#{column} IS NULL"
            elsif condition.include_missing?
              "(#{collection_overlap_sql(scope, column, values)} OR #{column} IS NULL)"
            else
              collection_overlap_sql(scope, column, values)
            end
          end

          # Takes the scope rather than the index, so the table comes from the scope the caller
          # already built. A sharded adapter picks one of many tables before this runs, and asking
          # model_for(index) here would either raise or name the wrong one.
          def collection_overlap_sql(scope, column, values)
            raise NotImplementedError, "#{self.class} must implement collection_overlap_sql"
          end

          def collection_range_sql(scope, column, range, numeric)
            raise NotImplementedError, "#{self.class} must implement collection_range_sql"
          end

          # An endpoint may be absent, which is the documented unbounded end of a Range.
          def range_bounds(range)
            [ range.begin&.as_json, range.end&.as_json, range.exclude_end? ]
          end

          # ActiveRecord already compiles absence the way every adapter has to:
          # where(f: nil) is IS NULL, where(f: [ 1, nil ]) is IN (1) OR IS NULL,
          # and where.not of either negates the whole condition.
          def filter_value_for(condition)
            if condition.missing_only?
              nil
            elsif condition.include_missing?
              condition.value + [ nil ]
            else
              condition.value
            end
          end

          def apply_filter(scope, field, value)
            scope.where(field => value)
          end

          # COALESCE for the same reason as apply_not_group: where.not(f: v) is NOT(f = v), which is
          # UNKNOWN rather than true where f is NULL, so a document missing the field escapes the
          # rejection.
          def apply_not_filter(scope, field, value)
            ast = scope.klass.all.where(field => value).where_clause.ast
            scope.where.not(Arel::Nodes::NamedFunction.new("COALESCE", [ ast, Arel::Nodes.build_quoted(false) ]))
          end

          def apply_sort(scope, sort_criteria, has_query)
            if sort_criteria.empty? && has_query
              return scope.order(Arel.sql(score_order))
            end

            sort_criteria.each do |criterion|
              scope = apply_single_sort(scope, criterion)
            end
            scope
          end

          def apply_single_sort(scope, criterion)
            if criterion == Score
              scope.order(Arel.sql(score_order))
            else
              field, direction = parse_sort(criterion)
              scope.order(field => direction)
            end
          end

          # Overridden where the score is not higher-is-better: SQLite's FTS5 rank is negative.
          def score_order
            "score DESC"
          end
      end
    end
  end
end
