module ActiveSearch
  module Source # :nodoc: all
    class Polymorphic < Base
      attr_reader :type_column

      # name is the role the pair records -- searchable_type, searchable_id -- and index_name keys
      # the model's has_search declaration. They differ whenever polymorphic: names a role.
      def initialize(name:, index_name: nil)
        super(name: name, index_name: index_name)
        @type_column = :"#{name}_type"
        @identity_fields = [ @type_column, @id_column ].freeze
        @storage_key_columns = @identity_fields
      end

      def identity_attributes_for(record)
        { type_column => record.class.name, id_column => record.id.to_s }
      end

      def type_filter_for(model_class)
        { type_column => model_class.name }
      end

      def storage_key(document_id)
        gid = GlobalID.parse(document_id)
        { type_column => gid.model_class.name, id_column => gid.model_id }
      end

      def build_document_id(stored)
        type = stored[type_column]
        id = stored[id_column]
        type ? "gid://#{GlobalID.app}/#{type}/#{id}" : id.to_s
      end

      def records_for(ids)
        gids_by_class = group_gids_by_class(ids)
        records = gids_by_class.flat_map do |model_class, gids|
          load_records_for_class(model_class, gids)
        end
        records_by_id = records.index_by { |r| id_for(r) }
        ids.filter_map { |id| records_by_id[id] }
      end

      def id_for(record)
        record.to_global_id.to_s
      end

      private
        def group_gids_by_class(ids)
          ids.each_with_object({}) do |id, hash|
            gid = GlobalID.parse(id)
            next unless gid
            begin
              model_class = gid.model_class
              (hash[model_class] ||= []) << gid
            rescue NameError
              # An id naming a class that no longer exists is skipped.
            end
          end
        end

        # Each class's own declaration, evaluated against the class being loaded so an STI
        # subclass scopes to itself.
        def load_records_for_class(model_class, gids)
          scope_for(model_class).where(model_class.primary_key => gids.map(&:model_id)).to_a
        end

        # A class with no declaration loads its records unscoped. One that returns nothing is a mistake.
        def scope_for(model_class)
          declaration = declaration_for(model_class)
          return model_class.all unless declaration

          relation = model_class.instance_exec(&declaration)
          unless relation.is_a?(::ActiveRecord::Relation) && relation.klass <= model_class
            raise QueryError,
              "the scope declared for #{model_class.name} does not load it, got #{relation.inspect}"
          end

          relation
        end

        def declaration_for(model_class)
          return unless model_class.respond_to?(:_index_reflections)

          model_class._index_reflections[index_name]&.options&.[](:scope)
        end
    end
  end
end
