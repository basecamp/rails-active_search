module ActiveSearch
  class IndexReflection # :nodoc:
    attr_reader :index_name, :options

    def initialize(index_name, options = {})
      @index_name = index_name
      @options = options
    end

    def index
      ActiveSearch.index(@index_name)
    end

    def reindex_on_touch?
      !!options[:reindex_on_touch]
    end

    # Async re-decides at perform, so a late job writes the current row, not a stale one. A destroy
    # carries its id; sync has no job to reorder, so it decides inline.
    def update(record)
      if record.destroyed?
        remove(record) if should_remove?(record)
      elsif async?
        index.reindex_later(record)
      else
        update_now(record)
      end
    end

    def update_now(record)
      if should_add?(record)
        index.add(record)
      elsif should_remove?(record)
        index.remove(record)
      end
    end

    def remove(record)
      async? ? index.remove_later(record) : index.remove(record)
    end

    def serialize(record, definition)
      if serializer.nil?
        auto_serialize(record, definition)
      elsif serializer.is_a?(Symbol)
        record.public_send(serializer)
      elsif serializer.respond_to?(:call)
        serializer.call(record)
      else
        raise ConfigurationError,
          "Invalid serializer #{serializer.inspect}. Use a method name or something callable."
      end
    end

    def serializer
      options[:serializer]
    end

    def async?
      options.fetch(:async, true)
    end

    private
      def auto_serialize(record, definition)
        skip = index.source&.identity_fields || []
        definition.fields.each_with_object({}) do |field, data|
          next if skip.include?(field.name)
          data[field.name] = field.extract(record)
        end
      end

      def should_add?(record)
        !record.destroyed? && passes_guards?(record, :add)
      end

      # A stale purge (not destroyed) reads only remove_if/remove_unless, so with neither declared
      # nothing restricts it and the document goes. A destroy falls back to the shared guards too.
      def should_remove?(record)
        passes_guards?(record, :remove, fallback: record.destroyed?)
      end

      # Key presence, not truthiness: a guard may be a literal false, and reading it through ||
      # would invert it — and let an explicit add_if: false fall through to the shared :if.
      def passes_guards?(record, action, fallback: true)
        positive = guard_for(action, :if, fallback)
        negative = guard_for(action, :unless, fallback)

        (positive.nil? || evaluate_condition(record, positive)) &&
          (negative.nil? || !evaluate_condition(record, negative))
      end

      def guard_for(action, kind, fallback)
        if options.key?(:"#{action}_#{kind}")
          options[:"#{action}_#{kind}"]
        elsif fallback && options.key?(kind)
          options[kind]
        end
      end

      def evaluate_condition(record, condition)
        case condition
        when Symbol then record.send(condition)
        when Proc then condition.call(record)
        else condition
        end
      end
  end
end
