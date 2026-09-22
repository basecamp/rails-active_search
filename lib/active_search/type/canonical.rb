module ActiveSearch
  module Type # :nodoc: all
    # Active Model's casters are lenient because a database column is a second gate that refuses a
    # wrong type or a bad byte. A search store is not, so these types refuse rather than pass it on.
    module Canonical
      # Refused for every type: Active Model's String caster answers "[1, 2, 3]" for an Array, and
      # no field type here holds more than one value.
      def cast(value)
        if value.is_a?(Array) || value.is_a?(Hash)
          raise Invalid, "must be a single value, got #{value.class}"
        end

        cast = super
        raise Invalid, "is not a valid #{type}" if cast.nil?

        cast
      end
    end
  end
end
