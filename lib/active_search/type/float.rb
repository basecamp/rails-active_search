module ActiveSearch
  module Type # :nodoc: all
    class Float < ActiveModel::Type::Float
      include Canonical

      private
        # Finite only: "Infinity" casts to Infinity, which no JSON encoder can send. Not narrowed to
        # single precision, which would assume a 32-bit mapping this gem does not own.
        def cast_value(value)
          cast = super
          raise Invalid, "must be a finite Float" unless cast.finite?

          cast
        end
    end
  end
end
