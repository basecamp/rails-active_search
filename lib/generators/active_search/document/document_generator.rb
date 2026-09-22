require "rails/generators"
require "rails/generators/active_record"

module ActiveSearch
  module Generators # :nodoc: all
    # Writes the document model and migration a database-backed index needs. The adapter composes
    # the migration body; see MigrationSource#to_ruby.
    class DocumentGenerator < Rails::Generators::NamedBase # :nodoc:
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Write the migration that builds the document table for a database-backed index."

      def check_the_index_is_database_backed
        return if index.store.is_a?(ActiveSearch::StoreAdapters::Database)

        raise Rails::Generators::Error,
          "#{index.index_name} is not a database-backed index. Only those need a document class."
      end

      # Before anything is written, or a refusal leaves a class behind for a table the same run
      # declined to build. Not under revoke, where refusing would stop the removal half way.
      def refuse_a_structure_that_is_already_there
        index.store.refuse_creation!(index) unless behavior == :revoke
      rescue ActiveSearch::Schema::CreationRefused => e
        raise Rails::Generators::Error, e.message
      end

      # The migration path is read through the document class, which revoke deletes a step later.
      def resolve_destinations
        model_path
        migration_file
      end

      def create_model_file
        template "model.rb.tt", model_path
      end

      def create_migration_file
        migration_template "migration.rb.tt", migration_file
      end

      private
        def model_path
          @model_path ||= in_app ActiveSearch::StoreAdapters::Database::DocumentClass.path_for(index)
        end

        def migration_file
          @migration_file ||= File.join(in_app(index.store.migration_directory(index)),
            "#{migration_source.file_name}.rb")
        end

        # Thor resolves a relative path against destination_root, which is where a generator writes.
        def in_app(path)
          path = Pathname.new(path)
          path.to_s.start_with?("#{Rails.root}/") ? path.relative_path_from(Rails.root) : path
        end

        def index
          @index ||= ActiveSearch.index(name.to_sym)
        end

        def document_class_name
          ActiveSearch::StoreAdapters::Database::DocumentClass.constant_name_for(index)
        end

        # Only where the declaration has one. A field named type would otherwise make the
        # table single table inheritance, and the gem cannot put this in a class it does not own.
        def inheritance_column_field
          index.definition.field_names.map(&:to_s).find { |field| field == ActiveRecord::Base.inheritance_column }
        end

        # The template renders this and nothing else; the adapter composes the Ruby.
        def migration_source
          @migration_source ||= index.store.migration_source(index)
        end
    end
  end
end
