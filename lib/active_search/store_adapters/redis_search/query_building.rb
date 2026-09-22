module ActiveSearch
  module StoreAdapters
    class RedisSearch
      module QueryBuilding # :nodoc: all
        # FT.SEARCH cannot express an offset without a count, and 10 is the native page size, so an
        # offset with no limit pages the way Redis would.
        DEFAULT_LIMIT = 10

        # Dialect 2 is what makes ismissing() available. It needs Redis Search 2.10 or later with
        # INDEXMISSING on every filterable field.
        QUERY_DIALECT = 2

        private
          def build_search_query(query_context, definition = nil)
            query = query_context.query
            fields = query_context.fields
            filters = query_context.all_conditions.positive
            not_filters = query_context.all_conditions.negative

            filter_str = build_filter_string(filters, not_filters, definition)

            if query.blank?
              filter_str.present? ? filter_str : "*"
            else
              escaped_query = escape_query(query)
              query_str = build_field_query(escaped_query, fields)
              filter_str.present? ? "(#{query_str}) #{filter_str}" : query_str
            end
          end

          # Quoting, not backslash-escaping: an escaped token stays one token and cannot match the
          # punctuation-split index, where a quoted phrase is split the same way the document was.
          def escape_query(query)
            parts = query.dup.split(/("(?:[^"\\]|\\.)*")/)
            parts.map! do |part|
              if part.start_with?('"') && part.end_with?('"') && part.length > 1
                # Interior quotes and backslashes both go, or an escaped \" becomes a live quote
                # that closes the field and detaches the scoping filter appended after it.
                "\"#{part[1..-2].delete('"\\')}\""
              else
                quote_terms(part)
              end
            end

            parts.join(" ").squish
          end

          REDIS_BAREWORD = /\A\w+\z/
          STANDALONE_OPERATORS = /\A[|+\-*~]+\z/

          def quote_terms(text)
            text.split(/\s+/).filter_map { |term|
              unless term.empty? || term.match?(STANDALONE_OPERATORS)
                term.match?(REDIS_BAREWORD) ? term : "\"#{term.delete('"\\')}\""
              end
            }.join(" ")
          end

          def build_field_query(query_string, fields)
            return query_string if fields.blank?

            # Each branch of a multi-field query must be parenthesised: ((@f1:q)|(@f2:q)).
            if fields.size == 1
              "@#{fields.first}:(#{query_string})"
            else
              field_queries = fields.map { |f| "(@#{f}:(#{query_string}))" }
              "(#{field_queries.join('|')})"
            end
          end

          # Backslash-escaping is right here, unlike in the text query: a TAG value is one exact
          # token, never tokenized, so escaping keeps it whole. One pass including the backslash
          # itself, or it escapes the next escape. Slash and space are metacharacters too.
          SPECIAL_CHARS = /[\\,.<>{}\[\]'":;!@\#$%^&*()\-+=~|\/ ]/

          def escape_filter_value(value)
            value.to_s.gsub(SPECIAL_CHARS) { |char| "\\#{char}" }
          end

          def format_numeric(value)
            serialized = serialize_value(value)
            value_is_numeric?(value) ? serialized : escape_filter_value(serialized)
          end

          def missing_clause_for(field)
            "ismissing(@#{field})"
          end

          def build_filter_string(filters, not_filters, definition = nil)
            clauses = []

            filters.each do |condition|
              clauses << positive_clause(condition, definition)
            end

            not_filters.each { |condition| clauses << negative_clause(condition, definition) }

            clauses.join(" ")
          end

          # De Morgan, so the negation stays on the leaves where Redis Search's minus works.
          def negative_clause(condition, definition)
            if condition.is_a?(ActiveSearch::Conditions::Group)
              negated = condition.branches.map do |branch|
                "(#{branch.map { |c| negative_clause(c, definition) }.join(" | ")})"
              end
              "(#{negated.join(" ")})"
            elsif condition.missing_only?
              "-#{missing_clause_for(condition.field)}"
            elsif condition.include_missing?
              "-#{missing_clause_for(condition.field)} #{build_not_filter_clause(condition.field, condition.value, collection?(definition, condition.field))}"
            else
              build_not_filter_clause(condition.field, condition.value, collection?(definition, condition.field))
            end
          end

          def positive_clause(condition, definition)
            if condition.is_a?(ActiveSearch::Conditions::Group)
              group_clause(condition, definition)
            elsif condition.missing_only?
              missing_clause_for(condition.field)
            elsif condition.include_missing?
              "(#{build_filter_clause(condition.field, condition.value, collection?(definition, condition.field))} | #{missing_clause_for(condition.field)})"
            else
              build_filter_clause(condition.field, condition.value, collection?(definition, condition.field))
            end
          end

          # Terms AND by juxtaposition and | is looser, so a branch must be parenthesised.
          def group_clause(group, definition)
            return match_nothing_clause(any_filter_field(definition)) if group.branches.empty?

            branches = group.branches.map do |branch|
              "(#{branch.map { |condition| positive_clause(condition, definition) }.join(" ")})"
            end

            "(#{branches.join(" | ")})"
          end

          # A group carries no field of its own, so the field-shaped match-nothing borrows one. Any
          # filterable field will do: the clause is a contradiction whichever it names.
          def any_filter_field(definition)
            definition&.filter_fields&.keys&.first ||
              raise(QueryError, "filter_any([]) needs the index to declare a filterable field on this store")
          end

          # Redis Search has no empty disjunction — an empty numeric group is a syntax error and an
          # empty tag group invalid — so an empty group becomes a contradiction instead.
          def match_nothing_clause(field)
            "ismissing(@#{field}) -ismissing(@#{field})"
          end

          # A collection is indexed TAG whatever its element type, because a NUMERIC field holds one
          # number. Its integers take the tag branch, where a plain integer field takes the numeric.
          def collection?(definition, field)
            definition && definition[field]&.multiple?
          end

          def build_filter_clause(field, value, collection = false)
            case value
            when Range
              build_range_clause(field, value)
            when Array
              if value.empty?
                match_nothing_clause(field)
              elsif !collection && value.all? { |v| value_is_numeric?(v) }
                # Parenthesised, or the | binds looser than the clauses juxtaposed around it.
                "(" + value.map { |v| "@#{field}:[#{format_numeric(v)} #{format_numeric(v)}]" }.join(" | ") + ")"
              else
                values = value.map { |v| escape_filter_value(serialize_value(v)) }.join("|")
                "@#{field}:{#{values}}"
              end
            else
              if !collection && value_is_numeric?(value)
                "@#{field}:[#{format_numeric(value)} #{format_numeric(value)}]"
              else
                "@#{field}:{#{escape_filter_value(serialize_value(value))}}"
              end
            end
          end

          def build_not_filter_clause(field, value, collection = false)
            case value
            when Range
              build_not_range_clause(field, value)
            when Array
              if !collection && value.all? { |v| value_is_numeric?(v) }
                value.map { |v| "-@#{field}:[#{format_numeric(v)} #{format_numeric(v)}]" }.join(" ")
              else
                tag_values = value.map { |v| escape_filter_value(serialize_value(v)) }.join("|")
                "-@#{field}:{#{tag_values}}"
              end
            else
              if !collection && value_is_numeric?(value)
                "-@#{field}:[#{format_numeric(value)} #{format_numeric(value)}]"
              else
                "-@#{field}:{#{escape_filter_value(serialize_value(value))}}"
              end
            end
          end

          def build_range_clause(field, range)
            "@#{field}:[#{range_bounds(range)}]"
          end

          def build_not_range_clause(field, range)
            "-@#{field}:[#{range_bounds(range)}]"
          end

          # [min max], where a leading ( makes a bound exclusive.
          def range_bounds(range)
            start_val = range.begin ? format_numeric(range.begin) : "-inf"

            if range.end
              end_val = format_numeric(range.end)
              end_val = "(#{end_val}" if range.exclude_end?
            else
              end_val = "+inf"
            end

            "#{start_val} #{end_val}"
          end

          def value_is_numeric?(value)
            value.is_a?(Numeric) || value.is_a?(Time) || value.is_a?(DateTime) ||
              value.is_a?(ActiveSupport::TimeWithZone) || value.is_a?(::Date)
          end

          def build_search_args(query, sort_criteria, highlight_fields, highlight_opts, limit, offset, select_fields)
            args = [ query, "WITHSCORES", "SCORER", "BM25" ]

            if limit
              args.push("LIMIT", offset || 0, limit)
            elsif offset
              args.push("LIMIT", offset, DEFAULT_LIMIT)
            end

            if select_fields.present?
              args.push("RETURN", select_fields.size, *select_fields.map(&:to_s))
            end

            sort_field = build_sort(sort_criteria)
            if sort_field
              args.push("SORTBY", sort_field[:field], sort_field[:direction])
            end

            if highlight_opts && highlight_fields.present?
              args.push("HIGHLIGHT", "FIELDS", highlight_fields.size, *highlight_fields)
              args.push("TAGS", ActiveSearch::Highlighting::STORE_OPEN_MARKER, ActiveSearch::Highlighting::STORE_CLOSE_MARKER)
            end

            args.push("DIALECT", QUERY_DIALECT)

            args
          end

          # Redis Search has one SORTBY, so the first non-Score criterion wins.
          def build_sort(sort_criteria)
            sort_criteria.each do |criterion|
              next if criterion == Score
              field, direction = parse_sort(criterion)
              return { field: field.to_s, direction: direction.to_s.upcase }
            end
            nil
          end
      end
    end
  end
end
