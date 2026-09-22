module ActiveSearch
  module Type # :nodoc: all
    # Reads and writes what a store keeps as epoch seconds at midnight UTC. serialize and cast
    # live together so a write and its read-back cannot drift apart.
    #
    # Write +::Integer+ and +::String+ here. This namespace defines its own Integer and String, so
    # a bare constant matches a field type instead of the core class, and every branch misses.
    class EpochSecondsDate < ActiveModel::Type::Date
      def cast(value)
        case value
        when ::Integer then ::Time.at(value).utc.to_date
        when ::String then value.match?(/\A-?\d+\z/) ? ::Time.at(value.to_i).utc.to_date : super
        else super
        end
      end

      def serialize(value)
        value.to_time(:utc).to_i
      end
    end
  end
end
