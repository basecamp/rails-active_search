require "test_helper"

class EngineTest < ActiveSupport::TestCase
  searches :articles

  test "ActiveSearch.logger is wired to Rails.logger" do
    assert_not_nil ActiveSearch.logger
    assert_equal Rails.logger, ActiveSearch.logger
  end

  test "config.active_search is available" do
    assert_kind_of ActiveSupport::OrderedOptions, Rails.application.config.active_search
  end

  test "config.active_search.logger overrides Rails.logger when set" do
    custom = Logger.new(StringIO.new)
    original = ActiveSearch.logger

    begin
      Rails.application.config.active_search.logger = custom
      ActiveSearch.logger = Rails.application.config.active_search.logger || Rails.logger
      assert_equal custom, ActiveSearch.logger
    ensure
      Rails.application.config.active_search.logger = nil
      ActiveSearch.logger = original
    end
  end

  test "ActiveSearch is in eager_load_namespaces" do
    assert_includes Rails.application.config.eager_load_namespaces, ActiveSearch
  end

  test "LogSubscriber is attached to :active_search" do
    subscribers = ActiveSupport::LogSubscriber.log_subscribers.select { |s| s.is_a?(ActiveSearch::LogSubscriber) }
    assert subscribers.size >= 1, "Expected at least one ActiveSearch::LogSubscriber attached"
  end

  test "a prepare re-evaluates the index definitions" do
    before = ActiveSearch.index(:articles)

    Rails.application.reloader.prepare!

    after = ActiveSearch.index(:articles)
    assert_not_same before, after, "config/search.rb was not re-evaluated on prepare"
    assert_equal before.definition.fields.map(&:name), after.definition.fields.map(&:name)
  end

  test "a prepare drops an index the previous load defined and this one does not" do
    ActiveSearch.configuration.reloading_indexes do
      ActiveSearch.define_index(:since_deleted, source: "Article") { text :title }
    end

    assert_kind_of ActiveSearch::Index, ActiveSearch.index(:since_deleted)

    Rails.application.reloader.prepare!

    assert_raises(ActiveSearch::ConfigurationError) { ActiveSearch.index(:since_deleted) }
    assert_kind_of ActiveSearch::Index, ActiveSearch.index(:articles), "control: search.rb's own indexes survive"
  end

  test "a prepare keeps an index registered outside the reload" do
    ActiveSearch.define_index(:engine_provided, source: "Article") { text :title }

    Rails.application.reloader.prepare!

    assert_kind_of ActiveSearch::Index, ActiveSearch.index(:engine_provided)
  ensure
    ActiveSearch.configuration.unregister_index(:engine_provided)
  end

  test "repeated prepares neither raise nor duplicate an index" do
    3.times { Rails.application.reloader.prepare! }

    assert_equal 1, ActiveSearch.configuration.send(:instance_variable_get, :@indexes).keys.count(:articles)
    assert_kind_of ActiveSearch::Index, ActiveSearch.index(:articles)
  end

  test "an index rebuilt by a prepare still hydrates records" do
    article = Article.create!(title: "Reloaded", content: "Content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    Rails.application.reloader.prepare!

    results = ActiveSearch.index(:articles).search("Reloaded").results
    assert_equal [ article.id ], results.map(&:id)
  ensure
    ActiveSearch.index(:articles).remove(article) if article
  end

  test "a prepare keeps a store whose adapter class is unchanged" do
    before = ActiveSearch.configuration.store_for(:default)

    Rails.application.reloader.prepare!

    assert_same before, ActiveSearch.configuration.store_for(:default)
  end

  test "store_names returns :default for single store config" do
    config = ActiveSearch::Configuration.new
    config.apply_store_config(adapter: :sqlite)

    assert_equal [ :default ], config.store_names
  end

  test "store_names returns named keys for multi-store config" do
    config = ActiveSearch::Configuration.new
    config.apply_store_config(primary: { adapter: :sqlite }, analytics: { adapter: :mysql })

    assert_includes config.store_names, :primary
    assert_includes config.store_names, :analytics
  end
end
