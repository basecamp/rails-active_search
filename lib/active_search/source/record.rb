module ActiveSearch
  module Source # :nodoc: all
    class Record < Base
      def initialize(name:, index_name: nil, source_class_name: nil, query_scope: nil)
        super(name: name, index_name: index_name)
        @source_class_name = source_class_name
        @query_scope = query_scope
      end

      def model_class
        @model_class ||= resolve_class
      end

      def records_for(ids)
        unless active_record_class?(model_class)
          raise ConfigurationError,
            "Source class #{model_class.name} must inherit from ActiveRecord::Base"
        end

        key = model_class.primary_key
        scope.where(key => ids).in_order_of(key.to_sym, ids).to_a
      end

      # Both resolve here, so a default is evaluated at the same moment either way. A declaration
      # that returns nothing is a mistake, not an absence, so it is checked rather than fallen back.
      def scope
        base = declaration ? validated(model_class.instance_exec(&declaration)) : model_class.all
        @query_scope ? base.merge(validated(@query_scope)) : base
      end

      def with_scope(relation)
        validate_scope!(relation)
        self.class.new(name: name, index_name: index_name, source_class_name: @source_class_name,
          query_scope: relation)
      end

      def id_for(record)
        record.id.to_s
      end

      private
        def resolve_class
          class_name = @source_class_name || @name.to_s.classify
          class_name.constantize
        end

        # Results keys on id_for alone, so another model's relation would return its own records
        # wherever the ids collide.
        def validate_scope!(relation)
          unless relation.is_a?(::ActiveRecord::Relation)
            raise QueryError, "a scope must be an ActiveRecord::Relation, got #{relation.inspect}"
          end

          unless relation.klass <= model_class
            raise QueryError,
              "scope loads #{relation.klass.name} but :#{name} hydrates #{model_class.name}"
          end
        end

        def validated(relation)
          validate_scope!(relation)
          relation
        end

        def declaration
          return unless model_class.respond_to?(:_index_reflections)

          model_class._index_reflections[index_name]&.options&.[](:scope)
        end

        def active_record_class?(klass)
          defined?(ActiveRecord::Base) && klass < ActiveRecord::Base
        end
    end
  end
end
