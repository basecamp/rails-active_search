module ActiveSearch
  module Type # :nodoc: all
    class String < ActiveModel::Type::String
      include Canonical

      private
        # Encode rather than scrub, so a bad byte sequence is refused rather than becoming a
        # replacement character. SQLite, Redis Search and Typesense otherwise store the document
        # and cannot return it.
        def cast_value(value)
          encoded = super.encode(Encoding::UTF_8)
          raise Invalid, "is not valid UTF-8" unless encoded.valid_encoding?

          encoded.freeze
        rescue Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
          raise Invalid, "is not valid UTF-8"
        end
    end
  end
end
