module ActiveSearch
  class Query
    module Normalization # :nodoc: all
      VALID_DIRECTIONS = %i[asc desc].freeze

      private
        def normalize_query_fields(fields)
          return nil if fields.nil?

          case fields
          when Symbol, String
            [ fields.to_sym ].freeze
          when Array
            fields.map(&:to_sym).freeze
          else
            raise QueryError, "query fields must be a Symbol, String or Array, got #{fields.class}"
          end
        end

        # A frozen copy, so mutating the caller's own String afterwards cannot change the query.
        def normalize_search_text(query)
          case query
          when nil then nil
          when String then query.strip.empty? ? nil : query.dup.freeze
          else raise QueryError, "search text must be a String or nil, got #{query.class}"
          end
        end

        def normalize_operator(operator)
          if operator.nil?
            nil
          elsif operator.respond_to?(:to_sym)
            normalized = operator.to_sym
            if %i[and or].include?(normalized)
              normalized
            else
              raise QueryError, "operator must be :and or :or, got #{operator.inspect}"
            end
          else
            raise QueryError, "operator must be a Symbol or String, got #{operator.class}"
          end
        end

        def normalize_hit_fields(fields)
          fields.map(&:to_sym)
        end

        # A Hash, specifically: an Array of pairs walks the same way here and would collapse a
        # repeated field to its last value.
        def normalize_filter_hash(filters)
          unless filters.is_a?(Hash)
            raise QueryError,
              "filter conditions must be given as a Hash, got #{filters.class}. " \
              "Repeat a field by chaining: filter(views: 100..).filter(views: ..200)"
          end

          filters.each_with_object({}) do |(key, value), hash|
            unless key.respond_to?(:to_sym)
              raise QueryError, "filter field names must be strings or symbols (got #{key.inspect})"
            end

            # "status" and :status are distinct Hash keys naming one field, so last-wins would drop
            # a condition the caller wrote.
            if hash.key?(key.to_sym)
              raise QueryError,
                "filter names #{key.to_sym.inspect} twice, as a String and a Symbol. " \
                "Repeat a field by chaining filter calls."
            end

            hash[key.to_sym] = value
          end
        end

        def normalize_sort(value)
          case value
          when Hash
            unless value.size == 1
              raise QueryError, "sort accepts one field at a time, got #{value.inspect}"
            end

            field, direction = value.first
            { field.to_sym => normalize_direction(direction) }
          when String
            # Copied, not frozen: freezing a String the caller still holds is a side effect on it.
            value.dup
          else
            value
          end
        end

        def normalize_direction(direction)
          normalized = direction.respond_to?(:to_sym) ? direction.to_sym : direction

          unless VALID_DIRECTIONS.include?(normalized)
            raise QueryError, "sort direction must be :asc or :desc, got #{direction.inspect}"
          end

          normalized
        end

        # Truncates like ActiveRecord, so limit(2.5) is LIMIT 2, but refuses a negative or a
        # non-number rather than turning it into a silent OFFSET 0. Base 10 is pinned for Strings:
        # Integer() honors radix prefixes, so "010" would otherwise be 8.
        def normalize_pagination(value, option)
          integer = value.is_a?(String) ? Integer(value, 10, exception: false) : Integer(value, exception: false)

          unless integer && !value.to_r.negative?
            raise QueryError, "#{option} must be a non-negative Integer, got #{value.inspect}"
          end

          integer
        end

        # Coerced rather than refused, unlike the other pagination values: a page number arrives
        # from a query string, where a junk value should render the first page and not raise.
        def normalize_page_number(value)
          [ value.to_i, 1 ].max
        end

        def normalize_per_page(value)
          sizes = Array.wrap(value).map { |n| normalize_pagination(n, :per_page) }

          if sizes.empty? || sizes.any?(&:zero?)
            raise QueryError, "per_page must be a positive Integer or a list of them, got #{value.inspect}"
          end

          sizes.freeze
        end

        # An empty Hash contributes nothing, so filter({}) is a no-op.
        def build_conditions(filters, negated:)
          normalized = normalize_filter_hash(filters)
          validate_filterable!(normalized.keys)

          normalized.filter_map do |name, value|
            build_condition(name, value, negated: negated)
          end
        end

        # One conjunction to negate, not several negations to AND, so reject picks out the
        # documents filter would have kept. Chaining reject(a).reject(b) still gives NOT(a OR b).
        def build_negated_conditions(filters)
          normalized = normalize_filter_hash(filters)
          validate_filterable!(normalized.keys)

          if normalized.size > 1
            branch = normalized.filter_map { |name, value| build_condition(name, value, negated: false) }
            # Every condition was unbounded, so the conjunction always holds and its negation cannot.
            return [ match_nothing_condition(normalized.keys.first) ] if branch.empty?
            # Negating a conjunction that cannot hold constrains nothing.
            return [] if branch.any?(&:matches_nothing?)

            [ Conditions::Group.new(branches: [ Conditions.new(branch) ], negated: true) ]
          else
            normalized.map { |name, value| build_condition(name, value, negated: true) }
          end
        end

        def build_group(branches)
          unless branches.is_a?(Array) && branches.all?(Hash)
            raise QueryError,
              "filter_any takes an Array of Hashes, one per alternative, got #{branches.inspect}"
          end

          if branches.any?(&:empty?)
            raise QueryError, "a filter_any alternative with no conditions matches every document. " \
              "Drop the alternative, or give it a field with an empty value list: { status: [] }."
          end

          built = branches.map { |b| Conditions.new(build_conditions(b, negated: false)) }

          # An alternative left empty by normalization always holds, so the whole group does too.
          built.any?(&:empty?) ? nil : Conditions::Group.new(branches: built)
        end

        def build_condition(name, value, negated:)
          # nil..nil bounds nothing: it drops here and its negation becomes match-nothing. Checked
          # first, so a condition that never compiles is not refused for a capability it cannot need.
          return negated ? match_nothing_condition(name) : nil if unbounded_range?(value)

          validate_collection_range!(name, value)

          if missing_filter?(value)
            validate_missing_filters!(name)

            Conditions::Condition.new(
              field: name,
              value: cast_array(name, filter_field_for(name), Array(value).compact),
              negated: negated,
              include_missing: true
            )
          else
            Conditions::Condition.new(
              field: name,
              value: cast_filter_value(name, value),
              negated: negated
            )
          end
        end

        def unbounded_range?(value)
          value.is_a?(Range) && value.begin.nil? && value.end.nil?
        end

        # A positive empty array, which every adapter already compiles to its own match-nothing.
        def match_nothing_condition(name)
          Conditions::Condition.new(field: name, value: [], negated: false)
        end

        # A nil scalar, or a nil inside an Array, asks for absence. A nil Range endpoint does not:
        # that is the unbounded endpoint.
        def missing_filter?(value)
          case value
          when nil then true
          when Array then value.any?(&:nil?)
          else false
          end
        end

        def cast_filter_value(name, value)
          field = filter_field_for(name)

          case value
          when Range then cast_range(name, field, value)
          when Array then cast_array(name, field, value)
          else cast_scalar(name, field, value)
          end
        end

        def filter_field_for(name)
          definition[name]
        end

        # Only a range endpoint truncates a datetime to whole seconds, so it compares the same way
        # whether the store keeps seconds or microseconds. An equality must match what was stored.
        def cast_range(name, field, range)
          first = range.begin && cast_boundary(name, field, range.begin)
          last = range.end && cast_boundary(name, field, range.end)

          Range.new(first, last, range.exclude_end?)
        end

        # An empty Array stays empty. Conditions gives it meaning: positive it matches nothing,
        # negated it excludes nothing.
        def cast_array(name, field, values)
          values.map { |value| cast_scalar(name, field, value) }
        end

        def cast_scalar(name, field, value)
          cast(name, field, value, field.caster)
        end

        def cast_boundary(name, field, value)
          cast(name, field, value, field.boundary_caster)
        end

        def cast(name, field, value, caster)
          if value.nil?
            raise QueryError, "filter value for '#{name}' cannot be nil"
          end

          caster.cast(value)
        rescue Type::Invalid => e
          raise QueryError, "filter value for '#{name}' #{e.message}"
        end
    end
  end
end
