require "test_helper"

# The persistent connection replaces RSolr's own, so it has to carry RSolr's middleware too.
# Without raise_error a 400 comes back as an ordinary response and a failed write reports success.
class SolrConnectionTest < ActiveSupport::TestCase
  searches :articles

  setup do
    skip "Solr only" unless store_adapter_name == :solr
  end

  test "a rejected request raises rather than parsing as a response" do
    client = ActiveSearch.index(:articles).store.send(:client, :articles)

    error = assert_raises(RSolr::Error::Http) do
      client.get("select", params: { q: "*:*", fq: "{!bogus}" })
    end

    assert_equal 400, error.response[:status]
  end

  test "the connection is persistent, which is the whole point of replacing RSolr's" do
    store = ActiveSearch.index(:articles).store

    assert store.send(:persistent_connection, "http://localhost:8983/solr/articles"),
      "faraday-net_http_persistent should be available in this bundle"
  end
end

# No skip: a dead server needs no live one, so every suite covers the failing half of ping.
class SolrPingTest < ActiveSupport::TestCase
  test "ping answers false when nothing is listening" do
    dead = ActiveSearch::StoreAdapters::Solr.new(url: "http://127.0.0.1:9/solr")

    assert_equal false, dead.ping
  end

  test "ping answers true against a live server" do
    skip "Solr only" unless ENV["SEARCH_ADAPTER"] == "solr"

    assert_equal true, ActiveSearch.index(:articles).store.ping
  end
end
