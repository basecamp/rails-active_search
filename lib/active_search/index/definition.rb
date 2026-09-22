module ActiveSearch
  class Index
    class Definition # :nodoc:
      attr_reader :fields

      def initialize(fields:)
        @fields = fields.freeze
        @by_name = fields.index_by(&:name).freeze
      end

      def search_fields
        @fields.select(&:searchable?).map(&:name).uniq
      end

      def searchable?(field_name)
        @by_name[field_name.to_sym]&.searchable?
      end

      # A string field is not searchable the way a text field is, but naming it in search(fields:)
      # is allowed where the store supports it. A number, boolean or date never is.
      def string_field?(field_name)
        @by_name[field_name.to_sym]&.type == :string
      end

      def filterable?(field_name)
        @by_name[field_name.to_sym]&.filterable?
      end

      def filter_fields
        @fields.select(&:filterable?).to_h { |f| [ f.name, f.type ] }
      end

      def [](name)
        @by_name[name.to_sym]
      end

      def field_names
        @fields.map(&:name).uniq
      end
    end
  end
end
