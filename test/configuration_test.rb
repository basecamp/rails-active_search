require "test_helper"

class ConfigurationTest < ActiveSupport::TestCase
  setup do
    @config = ActiveSearch::Configuration.new
  end

  test "apply_store_config loads working store" do
    @config.apply_store_config(adapter: :mysql)

    assert @config.store_for.ping, "Store loaded from config should be able to ping"
  end

  test "store_for returns same instance on repeated calls" do
    @config.apply_store_config(adapter: :sqlite)

    assert @config.store_for.ping, "First call should return working store"
    assert @config.store_for.ping, "Second call should return working store"
  end

  test "apply_store_config with named stores loads all stores" do
    @config.apply_store_config(primary: { adapter: :sqlite }, analytics: { adapter: :mysql })

    assert @config.store_for(:primary).ping, "Primary store should be able to ping"
    assert @config.store_for(:analytics).ping, "Analytics store should be able to ping"
  end

  test "named stores are independent" do
    @config.apply_store_config(primary: { adapter: :sqlite }, analytics: { adapter: :mysql })

    analytics = @config.store_for(:analytics)
    primary = @config.store_for(:primary)

    assert primary.ping, "Primary store should work after accessing analytics first"
    assert analytics.ping, "Analytics store should work"
  end

  test "index with store_name uses the named store" do
    @config.apply_store_config(primary: { adapter: :sqlite }, analytics: { adapter: :mysql })

    idx = ActiveSearch::Index.new(:test_store_idx,
      definition: ActiveSearch::Index::Definition.new(
        fields: [ ActiveSearch::Index::Field.new(:title, :text) ]
      ),
      source: ActiveSearch::Source::Record.new(name: :test_store_idx),
      store_name: :analytics
    )
    @config.register_index(:test_store_idx, idx)

    previous = ActiveSearch.configuration
    begin
      ActiveSearch.instance_variable_set(:@configuration, @config)

      assert_kind_of ActiveSearch::StoreAdapters::Mysql, @config.index(:test_store_idx).store
    ensure
      ActiveSearch.instance_variable_set(:@configuration, previous)
    end
  end

  test "index without store_name uses default store" do
    @config.apply_store_config(adapter: :sqlite)

    idx = ActiveSearch::Index.new(:test_default_idx,
      definition: ActiveSearch::Index::Definition.new(
        fields: [ ActiveSearch::Index::Field.new(:title, :text) ]
      ),
      source: ActiveSearch::Source::Record.new(name: :test_default_idx)
    )
    @config.register_index(:test_default_idx, idx)

    assert @config.index(:test_default_idx).store.ping, "Index should fall back to default store"
  end

  test "missing index raises ConfigurationError" do
    assert_raises(ActiveSearch::ConfigurationError) do
      @config.index(:nonexistent)
    end
  end

  test "missing index raises with define_index suggestion" do
    error = assert_raises(ActiveSearch::ConfigurationError) do
      @config.index(:totally_unknown_xyz)
    end
    assert_match(/TotallyUnknownXyz/, error.message,
      "Error should include the class name that was attempted")
    assert_match(/define_index/, error.message,
      "Error should suggest using define_index")
  end

  class CustomAdapter < ActiveSearch::StoreAdapters::Base
    class << self
      attr_accessor :constructions
    end
    self.constructions = 0

    def initialize(**options)
      super
      self.class.constructions += 1
    end
  end

  class OtherAdapter < ActiveSearch::StoreAdapters::Base; end

  class NotAnAdapter; end

  module MissingClient
    def self.const_missing(name)
      raise LoadError, "cannot load such file -- fictional_client"
    end
  end

  setup { CustomAdapter.constructions = 0 }

  test "a registered adapter name resolves to its class" do
    @config.register_adapter(:custom, "ConfigurationTest::CustomAdapter")

    assert_equal CustomAdapter, @config.adapter_class_for(:custom)
  end

  test "a registered adapter builds the store its config names" do
    @config.register_adapter(:custom, "ConfigurationTest::CustomAdapter")
    @config.apply_store_config(adapter: :custom)

    assert_kind_of CustomAdapter, @config.store_for
  end

  test "a symbol names a class too" do
    @config.register_adapter(:custom, :"ConfigurationTest::CustomAdapter")

    assert_equal CustomAdapter, @config.adapter_class_for(:custom)
  end

  test "a class is refused, because a name is what defers loading it" do
    error = assert_raises(ActiveSearch::ConfigurationError) do
      @config.register_adapter(:custom, CustomAdapter)
    end

    assert_match(/must be registered with a class name rather than Class/, error.message)
    assert_match(/defers loading/, error.message)
  end

  test "an adapter name that is not a plain identifier is refused" do
    [ :"Bad", :"has space", :"1st", :"a:b", :"[x" ].each do |name|
      assert_raises(ActiveSearch::ConfigurationError, "#{name.inspect} was accepted") do
        @config.register_adapter(name, "ConfigurationTest::CustomAdapter")
      end
    end

    assert_nothing_raised { @config.register_adapter(:redis_search, "ConfigurationTest::CustomAdapter") }
  end

  test "an anonymous class and a non-name are refused the same way" do
    [ Class.new(ActiveSearch::StoreAdapters::Base), 42, nil ].each do |value|
      assert_raises(ActiveSearch::ConfigurationError, "#{value.inspect} was accepted") do
        @config.register_adapter(:custom, value)
      end
    end
  end

  test "a class that does not inherit from Base is refused when it resolves" do
    @config.register_adapter(:custom, "ConfigurationTest::NotAnAdapter")
    @config.apply_store_config(adapter: :custom)

    error = assert_raises(ActiveSearch::ConfigurationError) { @config.store_for }
    assert_match(/does not inherit from ActiveSearch::StoreAdapters::Base/, error.message)
  end

  test "a missing client library names the Gemfile rather than escaping as a LoadError" do
    @config.register_adapter(:needs_client, "ConfigurationTest::MissingClient::Adapter")

    error = assert_raises(ActiveSearch::ConfigurationError) { @config.adapter_class_for(:needs_client) }

    assert_match(/could not load its client library/, error.message)
    assert_match(/fictional_client/, error.message)
  end

  test "a class name that resolves to nothing says so" do
    @config.register_adapter(:absent, "ConfigurationTest::NoSuchAdapter")

    error = assert_raises(ActiveSearch::ConfigurationError) { @config.adapter_class_for(:absent) }

    assert_match(/which does not exist/, error.message)
  end

  test "re-registering a name replaces the mapping" do
    @config.register_adapter(:custom, "ConfigurationTest::CustomAdapter")
    @config.register_adapter(:custom, "ConfigurationTest::OtherAdapter")

    assert_equal OtherAdapter, @config.adapter_class_for(:custom)
  end

  test "a store built from a replaced class is discarded" do
    Object.const_set(:ReloadableAdapter, Class.new(ActiveSearch::StoreAdapters::Base))
    @config.register_adapter(:reloadable, "ReloadableAdapter")
    @config.apply_store_config(adapter: :reloadable)
    stale = @config.store_for

    Object.send(:remove_const, :ReloadableAdapter)
    Object.const_set(:ReloadableAdapter, Class.new(ActiveSearch::StoreAdapters::Base))

    @config.discard_replaced_stores

    assert_not_same stale, @config.store_for, "the store outlived the class it was built from"
    assert_instance_of ReloadableAdapter, @config.store_for
  ensure
    Object.send(:remove_const, :ReloadableAdapter) if Object.const_defined?(:ReloadableAdapter)
  end

  test "a store whose class is unchanged survives the hook" do
    @config.register_adapter(:custom, "ConfigurationTest::CustomAdapter")
    @config.apply_store_config(adapter: :custom)
    store = @config.store_for

    @config.discard_replaced_stores

    assert_same store, @config.store_for
    assert_equal 1, CustomAdapter.constructions, "the store was rebuilt for nothing"
  end

  test "the hook is a no-op before anything is built" do
    @config.apply_store_config(adapter: :sqlite)

    assert_nothing_raised { @config.discard_replaced_stores }
    assert_equal 0, CustomAdapter.constructions
  end

  test "a store whose adapter no longer resolves is discarded rather than raising here" do
    @config.register_adapter(:custom, "ConfigurationTest::CustomAdapter")
    @config.apply_store_config(adapter: :custom)
    @config.store_for

    @config.register_adapter(:custom, "ConfigurationTest::NoSuchAdapter")

    assert_nothing_raised { @config.discard_replaced_stores }
    assert_raises(ActiveSearch::ConfigurationError) { @config.store_for }
  end

  test "an unregistered adapter name names the remedy" do
    @config.apply_store_config(adapter: :nowhere)

    error = assert_raises(ActiveSearch::ConfigurationError) { @config.store_for }

    assert_match(/ActiveSearch.register_adapter\(:nowhere, "Your::AdapterClass"\)/, error.message)
    assert_match(/Registered adapters are .*sqlite/, error.message)
  end

  test "a registration by name follows a reloaded constant" do
    Object.const_set(:ReloadedAdapter, Class.new(ActiveSearch::StoreAdapters::Base))
    @config.register_adapter(:reloadable, "ReloadedAdapter")
    @config.apply_store_config(adapter: :reloadable)
    stale = @config.adapter_class_for(:reloadable)

    Object.send(:remove_const, :ReloadedAdapter)
    Object.const_set(:ReloadedAdapter, Class.new(ActiveSearch::StoreAdapters::Base))

    assert_not_equal stale, @config.adapter_class_for(:reloadable)
    assert_equal ReloadedAdapter, @config.adapter_class_for(:reloadable)
  ensure
    Object.send(:remove_const, :ReloadedAdapter) if Object.const_defined?(:ReloadedAdapter)
  end

  test "an index asks configuration for its store rather than memoising one" do
    @config.register_adapter(:swapped, "ConfigurationTest::CustomAdapter")
    @config.apply_store_config(adapter: :swapped)

    index = ActiveSearch::Index.new(:widgets,
      definition: ActiveSearch::Index::Definition.new(fields: ActiveSearch::Index::Schema.from_block(proc { text :title }, index_name: :widgets)))

    previous = ActiveSearch.configuration
    begin
      ActiveSearch.instance_variable_set(:@configuration, @config)

      assert_kind_of CustomAdapter, index.store

      @config.register_adapter(:swapped, "ConfigurationTest::OtherAdapter")
      @config.apply_store_config(adapter: :swapped)

      assert_kind_of OtherAdapter, index.store, "the index kept a store built from the old mapping"
    ensure
      ActiveSearch.instance_variable_set(:@configuration, previous)
    end
  end

  test "a store name that is not configured raises rather than falling back" do
    @config.apply_store_config(primary: { adapter: :sqlite }, analytics: { adapter: :sqlite })

    error = assert_raises(ActiveSearch::ConfigurationError) { @config.store_for(:missing) }

    assert_match(/Unknown store :missing/, error.message)
    assert_match(/primary, analytics/, error.message)
  end

  test "a single-store configuration answers only :default" do
    @config.apply_store_config(adapter: :sqlite)

    assert_kind_of ActiveSearch::StoreAdapters::Sqlite, @config.store_for(:default)

    error = assert_raises(ActiveSearch::ConfigurationError) { @config.store_for(:primary) }
    assert_match(/names a single store, which is :default/, error.message)
  end

  test "an index naming a store that is not configured fails when it is searched" do
    @config.apply_store_config(primary: { adapter: :sqlite })
    index = ActiveSearch::Index.new(:widgets,
      definition: ActiveSearch::Index::Definition.new(fields: ActiveSearch::Index::Schema.from_block(proc { text :title }, index_name: :widgets)),
      store_name: :missing)

    previous = ActiveSearch.configuration
    begin
      ActiveSearch.instance_variable_set(:@configuration, @config)

      error = assert_raises(ActiveSearch::ConfigurationError) { index.store }
      assert_match(/Unknown store :missing/, error.message)
    ensure
      ActiveSearch.instance_variable_set(:@configuration, previous)
    end
  end

  test "a malformed store entry names itself rather than failing obscurely" do
    @config.apply_store_config(primary: "sqlite")

    error = assert_raises(ActiveSearch::ConfigurationError) { @config.store_for(:primary) }
    assert_match(/Store :primary must be configured with a Hash, got String/, error.message)
  end

  test "defining an index twice in one reloading pass raises rather than replacing the first" do
    error = assert_raises(ActiveSearch::ConfigurationError) do
      @config.reloading_indexes do
        @config.register_index(:same_pass_idx, registerable_index(:same_pass_idx))
        @config.register_index(:same_pass_idx, registerable_index(:same_pass_idx))
      end
    end

    assert_match(/Index :same_pass_idx is defined twice in config\/search.rb/, error.message)
  end

  test "re-registration across reloading passes replaces, which is how a reload works" do
    replacement = registerable_index(:cross_pass_idx)

    @config.reloading_indexes { @config.register_index(:cross_pass_idx, registerable_index(:cross_pass_idx)) }
    @config.reloading_indexes { @config.register_index(:cross_pass_idx, replacement) }

    assert_same replacement, @config.index(:cross_pass_idx)
  end

  test "re-registration outside a reloading pass replaces, so a boot-time redefinition still works" do
    replacement = registerable_index(:boot_idx)

    @config.register_index(:boot_idx, registerable_index(:boot_idx))
    @config.register_index(:boot_idx, replacement)

    assert_same replacement, @config.index(:boot_idx)
  end

  private
    def registerable_index(name)
      ActiveSearch::Index.new(name,
        definition: ActiveSearch::Index::Definition.new(
          fields: [ ActiveSearch::Index::Field.new(:title, :text) ]
        ))
    end
end
