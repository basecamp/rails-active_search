module ActiveSearch
  module Type # :nodoc: all
    # Reads and writes what a store keeps as epoch microseconds. serialize and cast live together
    # so a write and its read-back cannot drift apart.
    #
    # Write +::Integer+ and +::String+ here. This namespace defines its own Integer and String, so
    # a bare constant matches a field type instead of the core class, and every branch misses.
    class EpochMicrosecondsDateTime < ActiveModel::Type::DateTime
      MICROSECONDS = 1_000_000

      def cast(value)
        case value
        when ::Integer then at_microseconds(value)
        when ::String then value.match?(/\A-?\d+\z/) ? at_microseconds(value.to_i) : super
        else super
        end
      end

      # Through to_r: to_f rounds, losing the microsecond this type exists to keep.
      def serialize(value)
        (value.to_time.to_r * MICROSECONDS).round
      end

      private
        def at_microseconds(value)
          ::Time.at(Rational(value, MICROSECONDS)).utc
        end
    end
  end
end
