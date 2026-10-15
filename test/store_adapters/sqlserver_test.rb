require "test_helper"

class SqlserverTest < ActiveSupport::TestCase
  setup do
    skip "SQL Server tests require SEARCH_ADAPTER=sqlserver" unless store_adapter_name == :sqlserver
  end

  test "sanitizes terms into literal CONTAINS expressions" do
    store = ActiveSearch::StoreAdapters::Sqlserver.new

    assert_equal '"ruby" AND "guide"', store.send(:sanitize_contains_query, "ruby guide")
    assert_equal '"ruby guide" AND "today"', store.send(:sanitize_contains_query, '"ruby guide" today')
    assert_equal '"alpha" AND "beta"', store.send(:sanitize_contains_query, "+alpha -beta")
  end

  test "omits SQL Server stopwords from plain term conjunctions" do
    store = ActiveSearch::StoreAdapters::Sqlserver.new
    stopwords = { "all" => true, "be" => true, "to" => true, "will" => true }

    assert_equal '"Fields"', store.send(:sanitize_contains_query, "All Fields", stopwords: stopwords)
    assert_equal '"Destroyed"', store.send(:sanitize_contains_query, "Will Be Destroyed", stopwords: stopwords)
    assert_empty store.send(:sanitize_contains_query, "To Be", stopwords: stopwords)
  end

  test "expects SQL Server's reported string type for collection columns" do
    field = ActiveSearch::Index::Field.new(:labels, :string, multiple: true)

    assert_equal "string", ActiveSearch::StoreAdapters::Sqlserver.new.expected_native_type(field)
  end

  test "generated migrations enable automatic full-text change tracking" do
    index = ActiveSearch.index(:articles)
    migration = index.store.migration_source(index).to_ruby

    assert_includes migration, "WITH CHANGE_TRACKING AUTO"
    assert_no_match(/CHANGE_TRACKING MANUAL/, migration)
  end

  test "refresh resolves a configured store index name and accepts an already idle population" do
    index = ActiveSearch.define_index(:sqlserver_refresh_probe, source: "Article",
      index_name: :aliased_articles, document_class: "ArticleDocument") { text :title; text :content }
    ActiveSearch.define_index(:sqlserver_other_store_probe, source: "Article",
      store_name: :primary, index_name: :aliased_articles,
      document_class: "ArticleDocument") { text :title; text :content }

    assert_nothing_raised { index.store.refresh(index.index_name) }
  ensure
    ActiveSearch.configuration.unregister_index(:sqlserver_refresh_probe)
    ActiveSearch.configuration.unregister_index(:sqlserver_other_store_probe)
  end
end
