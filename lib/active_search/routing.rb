module ActiveSearch
  # Which shards a query goes to, for an index that declares +route_by+.
  #
  # Elasticsearch pins a document to one shard by its routing value, and reads only the shards a
  # search names. It is the only adapter that uses the value; the rest ignore it.
  #
  # The value comes from the query's own filters, and every rule below is about not reading a shard
  # that could hold a match:
  #
  # * a list routes to the union of those shards, comma-separated.
  # * repeated filters intersect, because they AND. [ 1, 2 ] then [ 2, 3 ] can only match 2. An
  #   empty intersection raises, because the query can match nothing.
  # * a Range is refused: its shards cannot be enumerated.
  # * a negation is ignored, since "not account 1" can match anywhere. The query reads every shard.
  #
  # A condition the framework set wins over a caller's, so model scoping on a polymorphic index
  # cannot be moved to another account's shards.
  module Routing # :nodoc:
    class << self
      def resolve(route_by, query_context)
        return nil if route_by.nil?

        value_from(route_by, query_context.protected_conditions, "protected conditions") ||
          value_from(route_by, query_context.conditions, "conditions")
      end

      private
        # One value, a list, or nil. A predicate including absence is skipped like a negation: a
        # document with no routing value is placed by its id, so it can be on any shard.
        def value_from(route_by, conditions, description)
          positive = conditions.positive
          predicates = positive.for_field(route_by).reject(&:include_missing?)
          groups = positive.grep(Conditions::Group)

          sets = predicates.map { |condition| routable_values(route_by, condition) }
          sets += groups.filter_map { |group| group_values(route_by, group) }
          return nil if sets.empty?

          values = sets.reduce(:&)

          if values.empty?
            raise QueryError,
              "Filters on routing field '#{route_by}' have no value in common in #{description}, " \
              "so the query cannot match"
          end

          values.size == 1 ? values.first : values
        end

        # A group routes only when every branch names the field, and the branches union. Two passes,
        # so one loose branch settles it before a Range elsewhere has to be enumerated.
        def group_values(route_by, group)
          per_branch = group.branches.map do |branch|
            predicates = branch.positive.for_field(route_by).reject(&:include_missing?)
            return nil if predicates.empty?

            predicates
          end

          per_branch.map { |predicates|
            predicates.map { |condition| routable_values(route_by, condition) }.reduce(:&)
          }.reduce(:|)
        end

        def routable_values(route_by, condition)
          if condition.value.is_a?(Range)
            raise QueryError,
              "Routing field '#{route_by}' cannot be filtered by a Range. Use a value or a list " \
              "of values."
          end

          Array(condition.value)
        end
    end
  end
end
