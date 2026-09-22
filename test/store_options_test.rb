require "test_helper"

class StoreOptionsTest < ActiveSupport::TestCase
  setup { @config = ActiveSearch::Configuration.new }

  test "returns what was configured, without the adapter name" do
    @config.apply_store_config(adapter: :sqlite, cluster: "primary", api_key: "secret")

    assert_equal({ cluster: "primary", api_key: "secret" }, @config.store_options)
  end

  test "reads a named store" do
    @config.apply_store_config(primary: { adapter: :sqlite, cluster: "one" },
                               analytics: { adapter: :sqlite, cluster: "two" })

    assert_equal "one", @config.store_options(:primary)[:cluster]
    assert_equal "two", @config.store_options(:analytics)[:cluster]
  end

  test "does not build the store" do
    connecting = Class.new(ActiveSearch::StoreAdapters::Base) do
      def initialize(**)
        raise "constructor contacted its backend"
      end
    end
    def connecting.name
      "StoreOptionsTest::Connecting"
    end
    Object.const_set(:StoreOptionsTestConnecting, connecting)

    @config.register_adapter(:connecting, "StoreOptionsTestConnecting")
    @config.apply_store_config(adapter: :connecting, cluster: "primary")

    assert_equal "primary", @config.store_options[:cluster]
    assert_raises(RuntimeError) { @config.store_for }
  ensure
    Object.send(:remove_const, :StoreOptionsTestConnecting) if Object.const_defined?(:StoreOptionsTestConnecting)
  end

  test "an unconfigured store name raises rather than answering nothing" do
    @config.apply_store_config(primary: { adapter: :sqlite })

    assert_raises(ActiveSearch::ConfigurationError) { @config.store_options(:missing) }
  end

  test "is reachable from the top level, which is where an application asks" do
    assert_respond_to ActiveSearch, :store_options
    assert_kind_of Hash, ActiveSearch.store_options
  end
end
