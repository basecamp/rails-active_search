module ActiveSearch
  module Type # :nodoc: all
    # Casts each element of a multiple: field with the element type, so an indexed collection and a
    # filter naming one of its values are written the same way.
    #
    # Only documents use this. A filter keeps the element caster, because filter(folder_ids: [ 1, 2 ])
    # names two values to look for rather than a collection to match whole.
    class Multiple
      attr_reader :element

      def initialize(element)
        @element = element
        freeze
      end

      # A bare value counts as one element, so a serializer need not wrap a single value itself.
      def cast(value)
        case value
        when ::Hash
          raise Invalid, "must be a collection of single values, got Hash"
        when ::Array
          value.map { |member| cast_element(member) }
        else
          [ cast_element(value) ]
        end
      end

      def type
        element.type
      end

      private
        # nil is absence, and a collection cannot hold one: an omitted field already says that.
        def cast_element(value)
          raise Invalid, "must not contain nil" if value.nil?

          element.cast(value)
        end
    end
  end
end
