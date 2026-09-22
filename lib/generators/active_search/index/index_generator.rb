require "rails/generators"
require "generators/active_search/document/document_generator"

module ActiveSearch
  module Generators # :nodoc: all
    class IndexGenerator < Rails::Generators::NamedBase # :nodoc:
      source_root File.expand_path("templates", __dir__)

      argument :fields, type: :array, default: [], banner: "field:type field:type"

      MODIFIERS = %w[ multiple ].freeze
      SEARCH_CONFIG = "config/search.rb".freeze

      def check_model_and_fields
        raise Rails::Generators::Error, "Give at least one field, as in title:text" if fields.empty?

        raise Rails::Generators::Error, "config/search.rb is missing. Run rails active_search:install." unless
          search_config.exist?

        declarations
        model_path
        @config_declared = ActiveSearch.index_names.include?(index_name)
        declared.store
      end

      def declare_index
        if revoking? || !@config_declared
          append_to_file SEARCH_CONFIG, "\n#{block}"
        else
          say_status :skip, ":#{index_name} is already declared", :yellow
        end
      end

      def add_has_search
        if revoking? || !already_declared?
          inject_into_class model_path, class_name.demodulize, "  has_search\n"
        else
          say_status :skip, "#{class_name} already declares :#{index_name}", :yellow
        end
      end

      def write_the_document_class
        invoke DocumentGenerator, [ index_name.to_s ] if
          !@config_declared && declared.store.generates_document_class?
      end

      private
        def index_name
          model.table_name.to_sym.tap do |name|
            raise Rails::Generators::Error,
              "#{model.name} is on the #{name} table, which is not a name an index can take." unless
                ActiveSearch::Index::NAME_PATTERN.match?(name)
          end
        end

        def model
          @model ||= class_name.safe_constantize.tap do |klass|
            raise Rails::Generators::Error,
              "#{class_name} is not an Active Record model. Generate it first." unless
                klass.is_a?(Class) && klass < ActiveRecord::Base
          end
        end

        def block
          <<~RUBY
            ActiveSearch.define_index(:#{index_name}#{source_argument}) do
            #{declarations.map { |line| "  #{line}" }.join("\n")}
            end
          RUBY
        end

        def already_declared?
          model.respond_to?(:_index_reflections) && model._index_reflections.key?(index_name)
        end

        # With no source: an index loads records of whatever model its own name classifies to.
        def source_name
          model.name unless index_name.to_s.classify == model.name
        end

        def source_argument
          %(, source: "#{source_name}") if source_name
        end

        # config/search.rb was read at boot, before this run appended to it, so the document
        # generator sees the index only if this registers it — and before any file is written, so
        # a declaration the gem refuses is refused first.
        def declared
          @declared ||= @config_declared ? ActiveSearch.index(index_name) : register
        end

        def register
          declared_fields = built_fields
          ActiveSearch.define_index(index_name, **{ source: source_name }.compact) do
            declared_fields.each do |field|
              public_send(field.type, field.name, **(field.multiple? ? { multiple: true } : {}))
            end
          end
        rescue ActiveSearch::ConfigurationError => error
          raise Rails::Generators::Error, error.message
        end

        def declarations
          built_fields.map { |field| "#{field.type} :#{field.name}#{", multiple: true" if field.multiple?}" }
        end

        def built_fields
          @built_fields ||= fields.map { |field| build_field(field) }
        end

        def build_field(field)
          name, type, *modifiers = field.split(":")
          unknown = modifiers - MODIFIERS

          raise Rails::Generators::Error,
            "Unknown modifier #{unknown.first} on #{field}. The modifier is #{MODIFIERS.join(", ")}." if unknown.any?

          build(name, type.presence || "text", modifiers.include?("multiple"))
        end

        def build(name, type, multiple)
          raise Rails::Generators::Error,
            "#{name.inspect} is not a field name. Give a lowercase name such as title." unless
              ActiveSearch::Index::NAME_PATTERN.match?(name)

          ActiveSearch::Index::Field.new(name, type, multiple: multiple)
        rescue ActiveSearch::ConfigurationError => error
          raise Rails::Generators::Error, error.message
        end

        def search_config
          Pathname.new(File.expand_path(SEARCH_CONFIG, destination_root))
        end

        def revoking?
          behavior == :revoke
        end

        def model_file
          "app/models/#{class_name.underscore}.rb"
        end

        def model_path
          @model_path ||= Pathname.new(File.expand_path(model_file, destination_root)).tap do |path|
            raise Rails::Generators::Error,
              "#{model_file} is not there, so #{model.name} is not a model this can edit." unless path.exist?
          end
        end
    end
  end
end
