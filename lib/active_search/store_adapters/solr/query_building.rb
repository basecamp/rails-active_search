module ActiveSearch
  module StoreAdapters
    class Solr
      module QueryBuilding # :nodoc: all
        private
          def build_search_params(query_context, highlight_fields)
            has_query = query_context.query.present?

            params = { wt: "json" }

            if has_query
              # uq dereference stops leading local params selecting a parser.
              params[:q] = "{!edismax v=$uq}"
              params[:uq] = query_context.query
              params[:qf] = query_context.fields.join(" ")
              params[:uf] = "-*"
            else
              params[:q] = "*:*"
            end

            if query_context.operator
              params["q.op"] = query_context.operator.to_s.upcase
            end

            fq = build_filter_queries(query_context.all_conditions.positive, query_context.all_conditions.negative)
            params[:fq] = fq if fq.any?

            sort_result = build_sort(query_context.sort, has_query)
            if sort_result
              params[:sort] = sort_result
            end

            if query_context.highlight_opts && highlight_fields.present?
              params[:hl] = true
              params["hl.fl"] = highlight_fields.join(",")

              snippeted = false
              highlight_fields.each do |field|
                field_opts = query_context.highlight_opts.for_field(field)
                params["f.#{field}.hl.simple.pre"] = ActiveSearch::Highlighting::STORE_OPEN_MARKER
                params["f.#{field}.hl.simple.post"] = ActiveSearch::Highlighting::STORE_CLOSE_MARKER
                # Per field, because a global fragsize truncates every field to the first
                # snippet spec's size. 0 returns the whole field.
                params["f.#{field}.hl.fragsize"] = field_opts.snippet? ? snippet_chars_for(field_opts) : 0
                snippeted ||= field_opts.snippet?
              end

              # Required for fragsize to work
              params["hl.bs.type"] = "WORD" if snippeted
            end

            params
          end

          # Solr expresses presence as field:* and absence as its negation, anchored with *:*
          # because a purely negative clause matches nothing inside a parenthesised expression.
          def present_query(field)
            "#{field}:*"
          end

          def missing_query(field)
            "(*:* -#{field}:*)"
          end

          def build_filter_queries(filters, not_filters)
            queries = []

            filters.each do |condition|
              clause = positive_query(condition)
              queries << clause if clause.present?
            end

            not_filters.each do |condition|
              clause = if condition.is_a?(ActiveSearch::Conditions::Group)
                negated_group_query(condition)
              elsif condition.missing_only?
                present_query(condition.field)
              elsif condition.include_missing?
                # Negating "value or absent" means present and not the value.
                "(#{present_query(condition.field)} AND #{build_not_filter_query(condition.field, condition.value)})"
              else
                build_not_filter_query(condition.field, condition.value)
              end

              queries << clause if clause.present?
            end

            queries
          end

          # Solr has no empty disjunction: field:() is a parser syntax error, so
          # an empty IN compiles to Solr's match-nothing clause instead.
          MATCH_NOTHING = "-*:*".freeze

          # Each leaf goes through the same negation the top level uses, or a missing-value
          # predicate loses its meaning inside a group.
          def negated_group_query(group)
            negated = group.branches.map do |branch|
              "(#{branch.map { |c| negative_query(c) }.join(" OR ")})"
            end

            "(#{negated.join(" AND ")})"
          end

          # Anchored with *:*, or a purely negative subquery matches nothing rather than everything
          # but its clause.
          def negative_query(condition)
            if condition.missing_only?
              present_query(condition.field)
            elsif condition.include_missing?
              "(#{present_query(condition.field)} AND #{build_not_filter_query(condition.field, condition.value)})"
            else
              "(*:* #{build_not_filter_query(condition.field, condition.value)})"
            end
          end

          def positive_query(condition)
            if condition.is_a?(ActiveSearch::Conditions::Group)
              group_query(condition)
            elsif condition.missing_only?
              missing_query(condition.field)
            elsif condition.include_missing?
              "(#{build_filter_query(condition.field, condition.value)} OR #{missing_query(condition.field)})"
            else
              build_filter_query(condition.field, condition.value)
            end
          end

          # Parenthesised at both levels, or Solr's default operator decides how a branch binds.
          def group_query(group)
            return MATCH_NOTHING if group.branches.empty?

            branches = group.branches.map do |branch|
              "(#{branch.map { |condition| positive_query(condition) }.reject(&:blank?).join(" AND ")})"
            end

            "(#{branches.join(" OR ")})"
          end

          def build_filter_query(field, value)
            case value
            when Range
              build_range_query(field, value)
            when Array
              if value.empty?
                MATCH_NOTHING
              else
                values = value.map { |v| format_filter_value(v) }.join(" OR ")
                "#{field}:(#{values})"
              end
            else
              "#{field}:#{format_filter_value(value)}"
            end
          end

          def build_not_filter_query(field, value)
            clause = build_filter_query(field, value)
            return "" if clause.blank? || clause == "*:*"
            "-#{clause}"
          end

          def build_range_query(field, range)
            # [inclusive TO inclusive], where a closing } makes the end exclusive.
            if range.begin && range.end
              start_bracket = "["
              end_bracket = range.exclude_end? ? "}" : "]"
              "#{field}:#{start_bracket}#{format_filter_value(range.begin)} TO #{format_filter_value(range.end)}#{end_bracket}"
            elsif range.begin
              "#{field}:[#{format_filter_value(range.begin)} TO *]"
            elsif range.end
              end_bracket = range.exclude_end? ? "}" : "]"
              "#{field}:[* TO #{format_filter_value(range.end)}#{end_bracket}"
            else
              "*:*"
            end
          end

          def format_filter_value(value)
            case value
            when String
              value.to_json
            when Time, DateTime, ActiveSupport::TimeWithZone
              # Quoted, or the ISO8601 colons parse as field separators.
              "\"#{value.utc.strftime("%Y-%m-%dT%H:%M:%SZ")}\""
            when ::Date
              # The query parser rejects a bare date -- Invalid Date String -- so it goes as midnight UTC.
              "\"#{value.strftime("%Y-%m-%dT00:00:00Z")}\""
            when TrueClass
              "true"
            when FalseClass
              "false"
            when Numeric
              value.to_s
            else
              value.to_s.to_json
            end
          end

          def build_sort(sort_criteria, has_query)
            if sort_criteria.empty?
              return has_query ? "score desc" : nil
            end

            sort_criteria.map do |criterion|
              build_single_sort(criterion)
            end.join(", ")
          end

          def build_single_sort(criterion)
            if criterion == Score
              "score desc"
            else
              field, direction = parse_sort(criterion)
              "#{field} #{direction}"
            end
          end
      end
    end
  end
end
