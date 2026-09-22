module ActiveSearch
  module StoreAdapters
    class Meilisearch
      module QueryBuilding # :nodoc: all
        private
          def build_search_params(query_context, highlight_fields, definition = nil)
            fields = query_context.fields
            filters = query_context.all_conditions.positive
            not_filters = query_context.all_conditions.negative
            sort_criteria = query_context.sort
            highlight_opts = query_context.highlight_opts

            params = {
              attributes_to_search_on: fields.presence || [ "*" ]
            }

            filter_string = build_filter_string(filters, not_filters, definition)
            if filter_string.present?
              params[:filter] = filter_string
            end

            sort_result = build_sort(sort_criteria)
            if sort_result.any?
              params[:sort] = sort_result
            end

            # highlight_fields alone is every search field, so only opts say highlighting was asked.
            if highlight_opts && highlight_fields.present?
              params[:attributes_to_highlight] = highlight_fields
              params[:highlight_pre_tag] = ActiveSearch::Highlighting::STORE_OPEN_MARKER
              params[:highlight_post_tag] = ActiveSearch::Highlighting::STORE_CLOSE_MARKER

              # FIELD:N, not a bare list plus one cropLength, so each field gets its own size.
              crop_attributes = highlight_fields.filter_map do |field|
                field_opts = highlight_opts.for_field(field)
                "#{field}:#{snippet_words_for(field_opts)}" if field_opts.snippet?
              end

              if crop_attributes.any?
                params[:attributes_to_crop] = crop_attributes
              end
            end

            params
          end

          def build_filter_string(filters, not_filters, definition = nil)
            clauses = filters.map { |condition| positive_clause(condition, definition) }

            not_filters.each { |condition| clauses << negative_clause(condition) }

            clauses.join(" AND ")
          end

          # De Morgan: negating a conjunction is a disjunction of the negations.
          def negative_clause(condition)
            if condition.is_a?(ActiveSearch::Conditions::Group)
              negated = condition.branches.map do |branch|
                "(#{branch.map { |c| negative_clause(c) }.join(" OR ")})"
              end
              "(#{negated.join(" AND ")})"
            elsif condition.missing_only?
              "#{condition.field} EXISTS"
            elsif condition.include_missing?
              "(#{condition.field} EXISTS AND #{build_not_filter_clause(condition.field, condition.value)})"
            else
              build_not_filter_clause(condition.field, condition.value)
            end
          end

          def positive_clause(condition, definition = nil)
            if condition.is_a?(ActiveSearch::Conditions::Group)
              group_clause(condition, definition)
            elsif condition.missing_only?
              "#{condition.field} NOT EXISTS"
            elsif condition.include_missing?
              "(#{build_filter_clause(condition.field, condition.value)} OR #{condition.field} NOT EXISTS)"
            else
              build_filter_clause(condition.field, condition.value)
            end
          end

          # Parenthesised at both levels, or a branch's ANDs bind looser than the OR above them.
          # A group carries no field of its own, so a field-shaped match-nothing borrows one. Any
          # filterable field will do -- an empty value list is a contradiction whichever it names.
          def group_clause(group, definition = nil)
            return borrowed_match_nothing(definition) if group.branches.empty?

            branches = group.branches.map do |branch|
              "(#{branch.map { |condition| positive_clause(condition, definition) }.join(" AND ")})"
            end

            "(#{branches.join(" OR ")})"
          end

          # No field-less way to say "nothing" here, so an empty value list borrows a field. An
          # index declaring only text fields has none and cannot say it at all.
          def borrowed_match_nothing(definition)
            field = definition&.filter_fields&.keys&.first
            unless field
              raise QueryError,
                "filter_any([]) needs the index to declare a filterable field on this store"
            end

            "#{field} IN []"
          end

          def build_filter_clause(field, value)
            case value
            when Range
              build_range_clause(field, value)
            when Array
              values = value.map { |v| format_value(v) }.join(", ")
              "#{field} IN [#{values}]"
            else
              "#{field} = #{format_value(value)}"
            end
          end

          def build_not_filter_clause(field, value)
            case value
            when Range
              build_not_range_clause(field, value)
            when Array
              values = value.map { |v| format_value(v) }.join(", ")
              "#{field} NOT IN [#{values}]"
            else
              "#{field} != #{format_value(value)}"
            end
          end

          def build_range_clause(field, range)
            clauses = []
            clauses << "#{field} >= #{format_value(range.begin)}" if range.begin
            if range.end
              op = range.exclude_end? ? "<" : "<="
              clauses << "#{field} #{op} #{format_value(range.end)}"
            end
            clauses.join(" AND ")
          end

          def build_not_range_clause(field, range)
            # NOT BETWEEN => field < begin OR field > end
            if range.begin && range.end
              op = range.exclude_end? ? ">=" : ">"
              "(#{field} < #{format_value(range.begin)} OR #{field} #{op} #{format_value(range.end)})"
            elsif range.begin
              "#{field} < #{format_value(range.begin)}"
            elsif range.end
              op = range.exclude_end? ? ">=" : ">"
              "#{field} #{op} #{format_value(range.end)}"
            else
              ""
            end
          end

          def format_value(value)
            case value
            when String
              value.to_json
            when Time, DateTime, ActiveSupport::TimeWithZone
              type_casters[:datetime].serialize(value)
            when ::Date
              type_casters[:date].serialize(value)
            when Numeric, TrueClass, FalseClass
              value
            else
              value.to_s.to_json
            end
          end

          def build_sort(sort_criteria)
            sort_criteria.flat_map do |criterion|
              build_single_sort(criterion)
            end
          end

          def build_single_sort(criterion)
            # Meilisearch cannot name score in a sort, so Score means default relevance: send none.
            return [] if criterion == Score

            field, direction = parse_sort(criterion)
            [ "#{field}:#{direction}" ]
          end
      end
    end
  end
end
