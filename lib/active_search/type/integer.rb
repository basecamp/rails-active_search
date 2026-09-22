module ActiveSearch
  module Type # :nodoc: all
    class Integer < ActiveModel::Type::Integer
      include Canonical

      # Eight bytes, like a Rails bigint, rather than Active Model's default of four: an integer
      # field in a search index is overwhelmingly a foreign key, and a Rails primary key is bigint.
      BYTES = 8

      def initialize(limit: BYTES, **options)
        super(limit: limit, **options)
      end

      private
        # serialize_cast_value is what range-checks, and it takes an already cast value, so the check
        # cannot recurse back through cast. The range and the wording stay Active Model's.
        def cast_value(value)
          serialize_cast_value(super)
        rescue ::ActiveModel::RangeError => e
          raise Invalid, e.message
        end
    end
  end
end
