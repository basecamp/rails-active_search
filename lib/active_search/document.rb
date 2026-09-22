module ActiveSearch
  class Document # :nodoc:
    attr_reader :id, :data, :definition

    def initialize(id:, data:, definition:, writable_fields: nil)
      @id = id.to_s
      @data = data.transform_keys(&:to_sym)
      @definition = definition
      @writable_fields = writable_fields
      validate_fields!
      cast_data!
      strip_highlight_sentinels!
      drop_absent_fields!
    end

    # Every declared field, or the observed subset after a typed adapter narrowed. The serializers
    # derive their columns from this, not from the definition.
    def writable_field_names
      @writable_fields || definition.field_names
    end

    def search_fields
      definition.search_fields & writable_field_names
    end

    def filter_field_names
      definition.filter_fields.keys & writable_field_names
    end

    # A copy carrying only the declared fields the store also holds. Identity keys survive because
    # the store holds them; a field the store lacks leaves both data and the writable set.
    def narrow_to(observed_names)
      writable = definition.field_names & observed_names.map(&:to_sym)
      Document.new(id: id, data: data.slice(*writable), definition: definition, writable_fields: writable)
    end

    # Writable fields this document does not supply. A merging store (Redis HSET, an upsert) must
    # clear them, or a field that became nil would keep its old value.
    def absent_fields
      writable_field_names - data.keys
    end

    def inspect
      "#<#{self.class.name} id: #{id.inspect}, data: #{data.inspect}>"
    end

    private
      def validate_fields!
        allowed = definition.field_names
        extra = @data.keys - allowed
        if extra.any?
          raise DocumentError, "Unknown fields: #{extra.join(', ')}. Defined fields: #{allowed.join(', ')}"
        end
      end

      def cast_data!
        definition.fields.each do |field|
          value = data[field.name]
          next if value.nil?

          begin
            data[field.name] = field.document_caster.cast(value)
          rescue Type::Invalid => e
            raise DocumentError, "value for '#{field.name}' #{e.message}"
          end
        end
      end

      # A highlight is a marker the store inserts, and a forged one renders identically, so text
      # containing those codepoints loses them on the way in.
      def strip_highlight_sentinels!
        pattern = /[#{Highlighting::STORE_OPEN_MARKER}#{Highlighting::STORE_CLOSE_MARKER}]/
        data.each do |name, value|
          data[name] = value.gsub(pattern, "") if value.is_a?(String)
        end
      end

      # A field supplied as nil is absent, the same as an omitted one, so nil never reaches an
      # adapter as a value. "", false and zero are present values and survive.
      def drop_absent_fields!
        @data = data.reject { |_name, value| value.nil? }
      end
  end
end
