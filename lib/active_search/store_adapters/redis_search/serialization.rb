module ActiveSearch
  module StoreAdapters
    class RedisSearch
      module Serialization # :nodoc: all
        private
          # Every supplied field is written, including "", false and zero. A blank string is a
          # present value, so a present? test here would drop it and leave whatever the hash held.
          def document_fields(document)
            document.data.to_h { |name, value| [ name.to_s, serialize_value(value) ] }
          end


          def serialize_value(value)
            case value
            when ::Array
              value.map { |member| serialize_value(member) }.join(COLLECTION_SEPARATOR)
            when Time, DateTime, ActiveSupport::TimeWithZone
              type_casters[:datetime].serialize(value).to_s
            when ::Date
              type_casters[:date].serialize(value).to_s
            when TrueClass
              "1"
            when FalseClass
              "0"
            when nil
              ""
            else
              value.to_s
            end
          end
      end
    end
  end
end
