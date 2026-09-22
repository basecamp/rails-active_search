module ActiveSearch
  module Type # :nodoc: all
    class Date < ActiveModel::Type::Date
      include Canonical

      private
        # Active Model passes an Integer, or any other object, straight through.
        def cast_value(value)
          cast = super
          raise Invalid, "must be a Date" unless cast.is_a?(::Date) && !cast.is_a?(::DateTime)

          cast
        end
    end
  end
end
