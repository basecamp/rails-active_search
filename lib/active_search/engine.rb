module ActiveSearch
  class Engine < ::Rails::Engine # :nodoc:
    isolate_namespace ActiveSearch

    config.active_search = ActiveSupport::OrderedOptions.new
    config.eager_load_namespaces << ActiveSearch

    # Validated at boot, so a bad value fails once rather than on every query.
    initializer "active_search.default_limit" do |app|
      app.config.active_search.default_limit = 25 unless app.config.active_search.key?(:default_limit)
      limit = app.config.active_search.default_limit

      unless limit.nil? || (limit.is_a?(Integer) && limit >= 0)
        raise ConfigurationError,
          "config.active_search.default_limit must be a non-negative Integer or nil, got #{limit.inspect}"
      end
    end

    initializer "active_search.logger" do
      config.after_initialize do |app|
        ActiveSearch.logger = app.config.active_search.logger || Rails.logger
      end
    end

    initializer "active_search.filter_attributes" do |app|
      ActiveSearch.filter_attributes = app.config.filter_parameters
    end

    initializer "active_search.configuration" do |app|
      config_path = app.root.join("config", "search.yml")
      if config_path.exist?
        config = app.config_for(:search)
        ActiveSearch.configuration.apply_store_config(config.to_h.deep_symbolize_keys)
      end
    end

    initializer "active_search.active_record" do
      ActiveSupport.on_load(:active_record) do
        include ActiveSearch::Indexable
      end
    end

    # Definitions name source classes, so they are reloadable code: to_prepare re-evaluates them
    # and drops the ones the last load defined, taking a deleted definition with them.
    initializer "active_search.indexes", after: "active_search.configuration" do |app|
      app.config.to_prepare do
        ActiveSearch.configuration.discard_replaced_stores

        search_config = app.root.join("config", "search.rb")

        ActiveSearch.configuration.reloading_indexes do
          load search_config if search_config.exist?
        end
      end
    end
  end
end
