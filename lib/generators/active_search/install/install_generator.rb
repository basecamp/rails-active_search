require "rails/generators"

module ActiveSearch
  module Generators # :nodoc: all
    class InstallGenerator < Rails::Generators::Base # :nodoc:
      source_root File.expand_path("templates", __dir__)

      class_option :adapter, type: :string, default: "sqlite",
        desc: "Which store development and test search through"

      def check_the_adapter_is_registered
        raise Rails::Generators::Error,
          ActiveSearch.configuration.send(:unregistered_adapter_message, adapter) unless registered?
      end

      def create_config_files
        template "search.yml.tt", "config/search.yml"
        template "search.rb.tt", "config/search.rb"
      end

      private
        def adapter
          options[:adapter].to_sym
        end

        def registered?
          ActiveSearch.configuration.registered_adapter_names.include?(adapter)
        end

        # By class, not a name list, so a new SQL adapter needs no edit here.
        def database_adapter?
          ActiveSearch.configuration.adapter_class_for(adapter) <= StoreAdapters::Database
        end

        # Typesense is the one adapter with a required option and no default for it.
        def api_key_needed?
          adapter == :typesense
        end
    end
  end
end
