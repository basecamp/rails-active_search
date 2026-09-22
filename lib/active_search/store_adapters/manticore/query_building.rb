module ActiveSearch
  module StoreAdapters
    class Manticore
      module QueryBuilding # :nodoc: all
        private
          def build_search_body(index_name, query_context, highlight_fields)
            body = {
              table: table_name_for(index_name)
            }

            must_clauses = []
            filter_clauses = []
            must_not_clauses = []

            if query_context.query.present?
              match_fields = query_context.fields.present? ? query_context.fields.map(&:to_s).join(",") : "*"
              must_clauses << { match: { match_fields => query_context.query } }
            end

            query_context.all_conditions.positive.each do |condition|
              filter_clauses << positive_clause(condition)
            end

            query_context.all_conditions.negative.each do |condition|
              if condition.is_a?(ActiveSearch::Conditions::Group)
                filter_clauses << negated_group_clause(condition)
              else
                must_not_clauses << build_filter_clause(condition.field, condition.value)
              end
            end

            if must_clauses.any? || filter_clauses.any? || must_not_clauses.any?
              body[:query] = { bool: {} }
              body[:query][:bool][:must] = must_clauses if must_clauses.any?
              body[:query][:bool][:filter] = filter_clauses if filter_clauses.any?
              body[:query][:bool][:must_not] = must_not_clauses if must_not_clauses.any?
            else
              body[:query] = { match_all: {} }
            end

            sort_result = build_sort(query_context.sort)
            if sort_result.any?
              body[:sort] = sort_result
            end

            if query_context.highlight_opts && highlight_fields.present?
              first_field_opts = query_context.highlight_opts.for_field(highlight_fields.first)

              if first_field_opts.snippet?
                body[:highlight] = {
                  fields: highlight_fields.map(&:to_s),
                  before_match: ActiveSearch::Highlighting::STORE_OPEN_MARKER,
                  after_match: ActiveSearch::Highlighting::STORE_CLOSE_MARKER,
                  limit: snippet_chars_for(first_field_opts)
                }
              else
                body[:highlight] = {
                  fields: highlight_fields.map(&:to_s),
                  before_match: ActiveSearch::Highlighting::STORE_OPEN_MARKER,
                  after_match: ActiveSearch::Highlighting::STORE_CLOSE_MARKER
                }
              end
            end

            body
          end

          # Manticore ignores an empty IN rather than rejecting it, so an empty array would match
          # every row. Storing id 0 auto-assigns a real one instead, so no document holds it and
          # equals id 0 matches nothing whatever the field's type.
          def match_nothing_clause
            { equals: { "id" => 0 } }
          end

          def positive_clause(condition)
            if condition.is_a?(ActiveSearch::Conditions::Group)
              group_clause(condition)
            else
              build_filter_clause(condition.field, condition.value)
            end
          end

          # De Morgan rather than a bool under must_not, which this server flattens to NOR.
          def negated_group_clause(group)
            negated = group.branches.map do |branch|
              { bool: { should: branch.map { |c| { bool: { must_not: [ positive_clause(c) ] } } } } }
            end

            { bool: { must: negated } }
          end

          def group_clause(group)
            return match_nothing_clause if group.branches.empty?

            {
              bool: {
                should: group.branches.map { |branch| { bool: { must: branch.map { |c| positive_clause(c) } } } }
              }
            }
          end

          def build_filter_clause(field, value)
            case value
            when Range
              build_range_clause(field, value)
            when Array
              if value.empty?
                match_nothing_clause
              else
                { in: { field.to_s => value.map { |v| serialize_value(v) } } }
              end
            else
              { equals: { field.to_s => serialize_value(value) } }
            end
          end

          def build_range_clause(field, range)
            conditions = {}
            conditions[:gte] = serialize_value(range.begin) if range.begin
            if range.end
              conditions[range.exclude_end? ? :lt : :lte] = serialize_value(range.end)
            end
            { range: { field.to_s => conditions } }
          end

          def build_sort(sort_criteria)
            sort_criteria.filter_map do |criterion|
              build_single_sort(criterion)
            end
          end

          # Relevance is Manticore's default order, so Score needs no sort entry.
          def build_single_sort(criterion)
            return nil if criterion == Score

            field, direction = parse_sort(criterion)
            { field.to_s => direction.to_s }
          end
      end
    end
  end
end
