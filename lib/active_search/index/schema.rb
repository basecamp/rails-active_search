module ActiveSearch
  class Index
    # Declares the fields stored in an Index.
    #
    # The block passed to ActiveSearch.define_index runs in a Schema. Each field name must use
    # lowercase letters, digits, and single underscores, starting with a letter. A declaration
    # raises ConfigurationError for an invalid name, unknown option, unsupported collection type,
    # or repeated field name.
    class Schema
      def initialize # :nodoc:
        @fields = []
      end

      # Declares a searchable full-text field.
      #
      #   text :title
      #
      # Values are cast to frozen UTF-8 Strings. Arrays and Hashes are rejected, and text fields do
      # not support +multiple: true+.
      def text(name, **options)
        @fields << { name: name.to_sym, type: :text, options: options }
      end

      # Declares an exact-match filter field.
      #
      #   string :status
      #   string :labels, multiple: true
      #
      # ==== Options
      #
      # * +:multiple+ - Accepts a collection of values when true; defaults to false.
      #
      # Values are cast to frozen UTF-8 Strings. A collection field accepts an Array or a single
      # value, which becomes a one-element Array, and rejects Hashes and nil members.
      def string(name, **options)
        @fields << { name: name.to_sym, type: :string, options: options }
      end

      # Declares a 64-bit integer filter field.
      #
      #   integer :account_id
      #   integer :tag_ids, multiple: true
      #
      # ==== Options
      #
      # * +:multiple+ - Accepts a collection of values when true; defaults to false.
      #
      # Values use Active Model's integer casting and must fit in a signed 64-bit integer. A
      # collection field accepts an Array or a single value and rejects Hashes and nil members.
      def integer(name, **options)
        @fields << { name: name.to_sym, type: :integer, options: options }
      end

      # Declares a floating-point filter field.
      #
      #   float :price
      #
      # Values use Active Model's float casting and must be finite. Arrays, Hashes, infinity, NaN,
      # and +multiple: true+ are rejected.
      def float(name, **options)
        @fields << { name: name.to_sym, type: :float, options: options }
      end

      # Declares a boolean filter field.
      #
      #   boolean :published
      #
      # Values use Active Model's boolean casting. Arrays, Hashes, values that cast to nil, and
      # +multiple: true+ are rejected.
      def boolean(name, **options)
        @fields << { name: name.to_sym, type: :boolean, options: options }
      end

      # Declares a UTC time filter field.
      #
      #   datetime :published_at
      #   datetime :seen_at, multiple: true
      #
      # ==== Options
      #
      # * +:multiple+ - Accepts a collection of values when true; defaults to false.
      #
      # Values use Active Model's datetime casting, must convert to Time, and are stored in UTC. A
      # collection field accepts an Array or a single value and rejects Hashes and nil members.
      def datetime(name, **options)
        @fields << { name: name.to_sym, type: :datetime, options: options }
      end

      # Declares a calendar-date filter field.
      #
      #   date :published_on
      #
      # Values use Active Model's date casting and must produce a Date. Arrays, Hashes, and
      # +multiple: true+ are rejected.
      def date(name, **options)
        @fields << { name: name.to_sym, type: :date, options: options }
      end

      def self.from_block(block, index_name: nil) # :nodoc:
        schema = new
        schema.instance_eval(&block)

        # One field per name: a store keeps a single field under a name, so declaring both text and
        # string for one would leave an exact filter matching a token of the analyzed text.
        seen = {}
        schema.raw_fields.map { |f|
          if seen[f[:name]]
            raise ConfigurationError,
              "Index :#{index_name} declares :#{f[:name]} twice, as #{seen[f[:name]]} and " \
              "#{f[:type]}. Use two names to search a value and filter it exactly."
          end

          seen[f[:name]] = f[:type]
          Field.new(f[:name], f[:type], **f[:options])
        }
      end

      def raw_fields # :nodoc:
        @fields
      end
    end
  end
end
