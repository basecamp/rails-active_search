module ActiveSearch
  module StoreAdapters
    class Typesense
      module Serialization # :nodoc: all
        private
          def document_body(document)
            serialized = document.data.transform_values { |v| serialize_value(v) }
            { "id" => gid_to_model_id(document.id) }.merge(serialized.stringify_keys)
          end

          def serialize_value(value)
            case value
            when nil
              nil
            when Time, DateTime, ActiveSupport::TimeWithZone
              type_casters[:datetime].serialize(value)
            when ::Date
              type_casters[:date].serialize(value)
            when Hash
              value.transform_values { |v| serialize_value(v) }
            when Array
              value.map { |v| serialize_value(v) }
            else
              value
            end
          end
      end
    end
  end
end
