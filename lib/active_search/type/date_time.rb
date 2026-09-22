module ActiveSearch
  module Type # :nodoc: all
    class DateTime < ActiveModel::Type::DateTime
      include Canonical

      private
        def cast_value(value)
          cast = super
          time = cast.try(:to_time) || cast
          raise Invalid, "must be a Time" unless time.is_a?(::Time)

          apply_precision(time.getutc)
        end

        def apply_precision(time)
          time
        end
    end
  end
end
