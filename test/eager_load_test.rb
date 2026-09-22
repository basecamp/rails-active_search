require "test_helper"

class EagerLoadTest < ActiveSupport::TestCase
  test "the engine eager-loads without error" do
    assert_nothing_raised { Rails.application.eager_load! }
  end

  test "every built-in adapter constant resolves" do
    names = %i[ Base Database Sqlite Mysql Postgresql Elastic Elasticsearch Opensearch
               Meilisearch Typesense Solr RedisSearch Manticore ]

    names.each do |name|
      assert ActiveSearch::StoreAdapters.const_get(name) < Object, "#{name} did not load"
    end
  end
end
