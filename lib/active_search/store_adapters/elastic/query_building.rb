module ActiveSearch
  module StoreAdapters
    class Elastic
      module QueryBuilding # :nodoc: all
        private
          def build_elastic_query(query_context, highlight_fields)
            filter_clauses = build_filter_clauses(query_context.all_conditions.positive)
            not_filter_clauses = build_filter_clauses(query_context.all_conditions.negative)
            has_query = query_context.query.present?

            bool_query = {
              must: has_query ? build_search_query(query_context) : { match_all: {} }
            }
            bool_query[:filter] = filter_clauses if filter_clauses.any?
            bool_query[:must_not] = not_filter_clauses if not_filter_clauses.any?

            result = {
              query: { bool: bool_query }
            }
            sort_result = build_sort(query_context.sort, has_query)
            result[:sort] = sort_result if sort_result.any?

            if query_context.highlight_opts && highlight_fields.present?
              field_configs = highlight_fields.each_with_object({}) do |field, h|
                field_opts = query_context.highlight_opts.for_field(field)
                config = {
                  pre_tags: [ ActiveSearch::Highlighting::STORE_OPEN_MARKER ],
                  post_tags: [ ActiveSearch::Highlighting::STORE_CLOSE_MARKER ]
                }
                if field_opts.snippet?
                  config[:fragment_size] = snippet_chars_for(field_opts)
                  config[:number_of_fragments] = 1
                else
                  config[:number_of_fragments] = 0  # 0 = return whole field
                end
                h[field] = config
              end

              result[:highlight] = { fields: field_configs }
            end

            result
          end

          def build_sort(sort_criteria, has_query)
            if sort_criteria.empty?
              return has_query ? [ { _score: { order: :desc } } ] : []
            end

            sort_criteria.map do |criterion|
              build_single_sort(criterion)
            end
          end

          def build_single_sort(criterion)
            if criterion == Score
              { _score: { order: :desc } }
            else
              field, direction = parse_sort(criterion)
              { field => { order: direction } }
            end
          end

          # simple_query_string parses the user's own phrases, exclusions and operators, so the
          # query goes through unchanged.
          def build_search_query(query_context)
            simple_query = {
              query: query_context.query,
              fields: query_context.fields
            }

            if query_context.operator
              simple_query[:default_operator] = query_context.operator.to_s.upcase
            end

            { simple_query_string: simple_query }
          end

          def build_filter_clauses(conditions)
            conditions.map { |condition| build_condition_clause(condition) }
          end

          # No alternatives is an OR of nothing, which [].any? already answers: nothing matches.
          def group_clause(group)
            return { match_none: {} } if group.branches.empty?

            {
              bool: {
                should: group.branches.map { |branch| { bool: { filter: build_filter_clauses(branch) } } },
                minimum_should_match: 1
              }
            }
          end

          # Absence is must_not exists, so a condition combining values with absence becomes a
          # should over the two. Negation wraps the whole clause, which the caller does by placing
          # it in must_not.
          def build_condition_clause(condition)
            if condition.is_a?(ActiveSearch::Conditions::Group)
              group_clause(condition)
            elsif condition.missing_only?
              missing_clause(condition.field)
            elsif condition.include_missing?
              {
                bool: {
                  should: [ build_filter_clause(condition.field, condition.value), missing_clause(condition.field) ],
                  minimum_should_match: 1
                }
              }
            else
              build_filter_clause(condition.field, condition.value)
            end
          end

          def missing_clause(field)
            { bool: { must_not: { exists: { field: field } } } }
          end

          def build_filter_clause(field, value)
            case value
            when Range
              build_range_clause(field, value)
            when Array
              { terms: { field => value.map { |v| serialize_value(v) } } }
            else
              { term: { field => serialize_value(value) } }
            end
          end

          def build_range_clause(field, range)
            conditions = {}
            conditions[:gte] = serialize_value(range.begin) if range.begin
            if range.end
              conditions[range.exclude_end? ? :lt : :lte] = serialize_value(range.end)
            end
            { range: { field => conditions } }
          end
      end
    end
  end
end
