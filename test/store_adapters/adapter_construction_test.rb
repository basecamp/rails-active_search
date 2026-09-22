require "test_helper"

# The first search of a process builds its store inside a web request, so a constructor that
# connects turns a cold request into a round trip to the backend. Every adapter here is built
# against an address nothing listens on, so one that connects raises.
class AdapterConstructionTest < ActiveSupport::TestCase
  UNREACHABLE_HOST = "127.0.0.1".freeze
  UNREACHABLE_PORT = 9 # discard, refused rather than timing out

  UNREACHABLE_OPTIONS = {
    elasticsearch: { hosts: [ { host: UNREACHABLE_HOST, port: UNREACHABLE_PORT } ] },
    opensearch: { hosts: [ { host: UNREACHABLE_HOST, port: UNREACHABLE_PORT } ] },
    solr: { url: "http://#{UNREACHABLE_HOST}:#{UNREACHABLE_PORT}/solr" },
    meilisearch: { url: "http://#{UNREACHABLE_HOST}:#{UNREACHABLE_PORT}" },
    typesense: { api_key: "unused", nodes: [ { host: UNREACHABLE_HOST, port: UNREACHABLE_PORT, protocol: "http" } ] },
    redis_search: { host: UNREACHABLE_HOST, port: UNREACHABLE_PORT },
    manticore: { host: UNREACHABLE_HOST, port: UNREACHABLE_PORT },
    postgresql: {},
    mysql: {},
    sqlite: {}
  }.freeze

  test "every built-in adapter name resolves to a class that inherits from Base" do
    UNREACHABLE_OPTIONS.each_key do |name|
      klass = ActiveSearch.configuration.adapter_class_for(name)

      assert_operator klass, :<, ActiveSearch::StoreAdapters::Base
    end
  end

  test "no built-in adapter contacts its backend when constructed" do
    UNREACHABLE_OPTIONS.each_key do |name|
      klass = ActiveSearch.configuration.adapter_class_for(name)
      options = UNREACHABLE_OPTIONS.fetch(name)

      begin
        klass.new(**options)
      rescue StandardError => e
        flunk "#{name} raised while being constructed against an unreachable address: #{e.class}: #{e.message}"
      end
    end
  end

  test "the options table covers every registered adapter, so a new one cannot go unchecked" do
    assert_equal ActiveSearch.configuration.registered_adapter_names.sort, UNREACHABLE_OPTIONS.keys.sort
  end
end
