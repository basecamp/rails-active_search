module ActiveSearch
  module StoreAdapters
    class Typesense
      module QueryBuilding # :nodoc: all
        private
          def build_search_params(query_context, highlight_fields, definition = nil)
            query = query_context.query
            fields = query_context.fields
            filters = query_context.all_conditions.positive
            not_filters = query_context.all_conditions.negative
            sort_criteria = query_context.sort
            highlight_opts = query_context.highlight_opts
            operator = query_context.operator

            has_query = query.present?

            params = {
              q: query.presence || "*",
              query_by: fields.join(",")
            }

            # Typesense defaults to AND with a token-dropping fallback, which a threshold of 0 ends.
            if operator == :and
              params[:drop_tokens_threshold] = 0
            elsif operator == :or
              # An approximation, not boolean OR: tokens drop only when the full match finds under 100 documents.
              params[:drop_tokens_threshold] = 100
            end

            filter_string = build_filter_string(filters, not_filters, definition)
            if filter_string.present?
              params[:filter_by] = filter_string
            end

            sort_result = build_sort(sort_criteria, has_query)
            if sort_result
              params[:sort_by] = sort_result
            end

            # highlight_fields alone is every search field, so only opts say highlighting was asked
            # for. "none" because Typesense highlights the query_by fields when the key is omitted.
            if highlight_opts && highlight_fields.present?
              params[:highlight_fields] = highlight_fields.join(",")
              params[:highlight_start_tag] = ActiveSearch::Highlighting::STORE_OPEN_MARKER
              params[:highlight_end_tag] = ActiveSearch::Highlighting::STORE_CLOSE_MARKER

              highlight_fields.each do |field|
                field_opts = highlight_opts.for_field(field)
                if field_opts.snippet?
                  # Typesense counts tokens per side, so halve the total.
                  params[:highlight_affix_num_tokens] = (snippet_words_for(field_opts) / 2.0).ceil
                  break
                end
              end
            else
              params[:highlight_fields] = "none"
            end

            params
          end

          def build_filter_string(filters, not_filters, definition = nil)
            clauses = []

            filters.each do |condition|
              clauses << positive_clause(condition, definition)
            end

            not_filters.each { |condition| clauses << negative_clause(condition) }

            clauses.join(" && ")
          end

          # De Morgan, because Typesense negates a field rather than an expression.
          def negative_clause(condition)
            if condition.is_a?(ActiveSearch::Conditions::Group)
              negated = condition.branches.map do |branch|
                "(#{branch.map { |c| negative_clause(c) }.join(" || ")})"
              end
              "(#{negated.join(" && ")})"
            else
              build_not_filter_clause(condition.field, condition.value)
            end
          end

          def positive_clause(condition, definition = nil)
            if condition.is_a?(ActiveSearch::Conditions::Group)
              group_clause(condition, definition)
            else
              build_filter_clause(condition.field, condition.value)
            end
          end

          # Parenthesised at both levels, or a branch's && binds looser than the || above it.
          def group_clause(group, definition = nil)
            return borrowed_match_nothing(definition) if group.branches.empty?

            branches = group.branches.map do |branch|
              "(#{branch.map { |condition| positive_clause(condition, definition) }.join(" && ")})"
            end

            "(#{branches.join(" || ")})"
          end

          # No field-less way to say "nothing" here, so an empty value list borrows a field. Any
          # filterable one will do: an empty list matches nothing whichever it names.
          def borrowed_match_nothing(definition)
            field = definition&.filter_fields&.keys&.first
            unless field
              raise QueryError,
                "filter_any([]) needs the index to declare a filterable field on this store"
            end

            "#{field}:=[]"
          end

          def build_filter_clause(field, value)
            case value
            when Range
              build_range_clause(field, value)
            when Array
              values = value.map { |v| format_value(v) }.join(",")
              "#{field}:=[#{values}]"
            else
              "#{field}:=#{format_value(value)}"
            end
          end

          def build_not_filter_clause(field, value)
            case value
            when Range
              build_not_range_clause(field, value)
            when Array
              values = value.map { |v| format_value(v) }.join(",")
              "#{field}:!=[#{values}]"
            else
              "#{field}:!=#{format_value(value)}"
            end
          end

          def build_range_clause(field, range)
            # field:[start..end], which has no exclusive form, so an excluded end goes as two tests.
            if range.begin && range.end
              if range.exclude_end?
                "#{field}:>=#{format_value(range.begin)} && #{field}:<#{format_value(range.end)}"
              else
                "#{field}:[#{format_value(range.begin)}..#{format_value(range.end)}]"
              end
            elsif range.begin
              "#{field}:>=#{format_value(range.begin)}"
            elsif range.end
              op = range.exclude_end? ? "<" : "<="
              "#{field}:#{op}#{format_value(range.end)}"
            else
              ""
            end
          end

          def build_not_range_clause(field, range)
            if range.begin && range.end
              op = range.exclude_end? ? ">=" : ">"
              "(#{field}:<#{format_value(range.begin)} || #{field}:#{op}#{format_value(range.end)})"
            elsif range.begin
              "#{field}:<#{format_value(range.begin)}"
            elsif range.end
              op = range.exclude_end? ? ">=" : ">"
              "#{field}:#{op}#{format_value(range.end)}"
            else
              ""
            end
          end

          def format_value(value)
            case value
            when Time, DateTime, ActiveSupport::TimeWithZone
              type_casters[:datetime].serialize(value)
            when ::Date
              type_casters[:date].serialize(value)
            when TrueClass
              "true"
            when FalseClass
              "false"
            when Numeric
              value.to_s
            else
              # Backticks are Typesense's string literal, which a special character needs.
              "`#{escape_literal(value.to_s)}`"
            end
          end

          # A backtick inside a backtick literal closes it, and Typesense honours no escape for one,
          # so a value carrying one would inject filter syntax. Unrepresentable, hence refused.
          def escape_literal(value)
            if value.include?("`")
              raise QueryError, "Typesense cannot represent a filter value containing a backtick: #{value.inspect}"
            end

            value.gsub("\\") { "\\\\" }
          end

          def build_sort(sort_criteria, has_query)
            if sort_criteria.empty?
              return has_query ? "_text_match:desc" : nil
            end

            sort_criteria.map do |criterion|
              build_single_sort(criterion)
            end.join(",")
          end

          def build_single_sort(criterion)
            if criterion == Score
              "_text_match:desc"
            else
              field, direction = parse_sort(criterion)
              "#{field}:#{direction}"
            end
          end
      end
    end
  end
end
