module ActiveSearch
  module Highlighting
    # What {Query#highlight}'s argument becomes, and what an adapter reads off the query context.
    # Every field answers through #for_field, named or not.
    class Options # :nodoc:
      # highlight: true - all fields with defaults
      # highlight: { title: true, content: { snippet: 10 } } - per-field options
      def initialize(value)
        @field_options = {}
        @default_options = FieldOptions.new

        case value
        when true
          # Defaults for every field.
        when Hash
          value.each do |field, field_value|
            @field_options[field.to_sym] = FieldOptions.new(field_value)
          end
        else
          raise QueryError, "Invalid highlight option: #{value.inspect}. Use true or a Hash of field options."
        end
      end

      def for_field(field)
        @field_options[field] || @default_options
      end

      def specific_fields?
        @field_options.any?
      end

      def requested_fields
        @field_options.keys
      end

      def any_snippet_with_unit?(unit)
        @field_options.values.any? { |opts| opts.snippet_unit == unit }
      end

      def multiple_marker_variants?
        marker_variants.size > 1
      end

      def multiple_snippet_variants?
        snippet_variants.size > 1
      end

      private
        def marker_variants
          @field_options.values.map { |opts| [ opts.open_marker, opts.close_marker ] }.uniq
        end

        # Asking for no snippet is a variant too: beside a field that wants one, a store carrying a
        # single global snippet setting has no way to say "this field and not that one".
        def snippet_variants
          @field_options.values.map { |opts| [ opts.snippet_unit, opts.snippet_value ] }.uniq
        end
    end
  end
end
