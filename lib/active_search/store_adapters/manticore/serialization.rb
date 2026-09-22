module ActiveSearch
  module StoreAdapters
    class Manticore
      module Serialization # :nodoc: all
        private
          # Skipping a nil is not absence in the row: attributes have no NULL, so an unset text
          # column reads back as "" where every other adapter answers nil.
          def document_body(document)
            body = { "_original_id" => gid_to_model_id(document.id) }
            document.data.each do |k, v|
              serialized = serialize_value(v)
              body[k.to_s] = serialized unless serialized.nil?
            end
            body
          end

          # A Manticore id is numeric, so a string one is hashed.
          def encode_id(id)
            id_str = id.to_s
            encoded = if id_str =~ /^\d+$/
              id_str.to_i
            else
              Digest::MD5.hexdigest(id_str)[0, 16].to_i(16)
            end

            # Manticore reads id 0 as auto-assign, so the document lands under a server-picked id
            # this adapter could never address again.
            if encoded.zero?
              raise DocumentError, "Manticore treats document id 0 as auto-assign, so #{id.inspect} cannot be stored or addressed"
            end

            encoded
          end

          def serialize_value(value)
            case value
            when Time, DateTime, ActiveSupport::TimeWithZone
              type_casters[:datetime].serialize(value)
            when ::Date
              type_casters[:date].serialize(value)
            when TrueClass
              1
            when FalseClass
              0
            when nil
              nil  # Explicit, so document_body can drop it
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
