module ActiveSearch
  module Schema # :nodoc: all
    # Caches store schema observations per key, the way ActiveRecord caches a table's columns.
    # compute_if_absent stores only what the block returned, so an observation that raised caches
    # nothing. A reset clears a key, but an observation already in flight can repopulate it.
    class ObservationCache
      def initialize
        @entries = Concurrent::Map.new
      end

      def fetch(key)
        @entries.compute_if_absent(key) { yield }
      end

      def reset(key = nil)
        key ? @entries.delete(key) : @entries.clear
      end

      # Clears a family of keys — every domain of one index — without knowing which were observed.
      def reset_matching(&matcher)
        @entries.each_key { |key| @entries.delete(key) if matcher.call(key) }
      end
    end
  end
end
