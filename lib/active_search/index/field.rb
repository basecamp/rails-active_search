module ActiveSearch
  class Index
    class Field # :nodoc: all
      attr_reader :name, :type

      # One type object per field type. They are stateless, so they are shared.
      CASTERS = {
        text: Type::String.new,
        string: Type::String.new,
        integer: Type::Integer.new,
        float: Type::Float.new,
        boolean: Type::Boolean.new,
        date: Type::Date.new,
        datetime: Type::DateTime.new
      }.freeze

      BOUNDARY_CASTERS = CASTERS.merge(datetime: Type::BoundaryDateTime.new).freeze

      VALID_TYPES = CASTERS.keys.freeze

      # Only the types every adapter can both store and filter as a collection. A text collection
      # would reach a full-text index as its inspect output; float, date and boolean filter as
      # scalars but have no collection filter on at least one adapter.
      MULTIPLE_TYPES = %i[ integer string datetime ].freeze

      def initialize(name, type, multiple: false, **options)
        @name = name.to_sym
        @type = type.to_sym
        @multiple = multiple
        validate!(options)
      end

      # Whether this field holds many values rather than one. Cardinality, not storage: a store may
      # keep the collection as a native array, a JSON column or a joined string.
      def multiple?
        @multiple
      end

      # The type that casts a filter value for this field. One value at a time, even where the field
      # holds many: filter(folder_ids: [ 1, 2 ]) names two values to look for, and each is cast alone.
      def caster
        CASTERS[type]
      end

      # The type that casts this field's value in a document. The same element type, wrapped where the
      # field holds many, so an indexed value and a value filtering for it still agree.
      def document_caster
        @document_caster ||= multiple? ? Type::Multiple.new(caster) : caster
      end

      def boundary_caster
        BOUNDARY_CASTERS[type]
      end

      def extract(record)
        if record.respond_to?(name)
          record.public_send(name)
        else
          raise ConfigurationError,
            "#{record.class} does not respond to :#{name}. Define the method, or pass a " \
            "serializer: to has_search."
        end
      end

      def searchable?
        @type == :text
      end

      def filterable?
        @type != :text
      end

      def role
        searchable? ? :searchable : :filterable
      end

      private
        def validate!(options)
          # The same pattern as an index name: this name becomes a SQL column, a document
          # attribute and a store field.
          unless NAME_PATTERN.match?(@name)
            raise ConfigurationError,
              "Invalid field name #{@name.inspect}: use lowercase letters and digits separated by " \
              "single underscores, starting with a letter."
          end

          unless VALID_TYPES.include?(@type)
            raise ConfigurationError, "Unknown field type :#{@type}. Field types are #{VALID_TYPES.join(", ")}."
          end

          # An unknown option raises: accepted and ignored, a weight: or analyzer: would do nothing.
          unless options.empty?
            raise ConfigurationError,
              "Unknown option#{"s" if options.size > 1} #{options.keys.map(&:inspect).join(", ")} on " \
              "field :#{@name}. multiple: is the only field option."
          end

          if @multiple && !MULTIPLE_TYPES.include?(@type)
            raise ConfigurationError,
              "Field :#{@name} cannot be multiple:. A field holds many values only when it is " \
              "#{MULTIPLE_TYPES.join(" or ")}, because those are the types every adapter can both " \
              "store and filter as a collection."
          end
        end
    end
  end
end
