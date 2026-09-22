module ActiveSearch
  class Index
    module Querying # :nodoc: all
      # Written out rather than derived from Query's method list, where a method moved into a
      # module would drop off silently. reachability_test compares this list with Query's public methods.
      delegate :search, :filter, :filter_any, :reject, :highlight, :sort, :sort_by_relevance,
        :limit, :offset, :page, :results, :routing, :hit_fields, :to_native_query, :native,
        to: :all

      # Returns a new Query scoped to this index.
      def all
        Query.new(index: self)
      end
    end
  end
end
