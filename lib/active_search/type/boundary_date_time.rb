module ActiveSearch
  module Type # :nodoc: all
    # A range endpoint truncates to whole seconds, so it compares the same way whether the store
    # keeps seconds or microseconds. A stored datetime and a filter equality keep their precision.
    class BoundaryDateTime < DateTime
      private
        def apply_precision(time)
          time.change(usec: 0)
        end
    end
  end
end
