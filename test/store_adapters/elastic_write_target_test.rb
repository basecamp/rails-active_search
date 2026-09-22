require "test_helper"

# An alias spans the index being drained and the one being filled. A read must intersect their
# mappings, but a write goes to the alias's write index alone — so write narrowing must carry that
# index's own mapping, or every write during a rollover silently drops the new field.
class ElasticWriteTargetTest < ActiveSupport::TestCase
  class FakeIndices
    def initialize(mappings, aliases)
      @mappings = mappings
      @aliases = aliases
    end

    def get_mapping(index: nil) = @mappings
    def get_alias(index: nil, name: nil) = @aliases
  end

  class FakeClient
    attr_reader :indices
    def initialize(indices) = @indices = indices
  end

  test "write narrowing keeps a field the write index maps" do
    mappings = {
      "articles_old" => { "mappings" => { "properties" => {
        "title" => { "type" => "text" } } } },
      "articles_new" => { "mappings" => { "properties" => {
        "title" => { "type" => "text" }, "status" => { "type" => "keyword" } } } }
    }
    aliases = {
      "articles_old" => { "aliases" => { "articles" => { "is_write_index" => false } } },
      "articles_new" => { "aliases" => { "articles" => { "is_write_index" => true } } }
    }

    adapter = ActiveSearch::StoreAdapters::Elasticsearch.new
    adapter.instance_variable_set(:@client, FakeClient.new(FakeIndices.new(mappings, aliases)))

    names = adapter.send(:observed_field_names, ActiveSearch.index(:articles)).map(&:to_sym)

    assert_includes names, :title, "the shared field did not survive, so this test proves nothing"
    assert_includes names, :status,
      "the write narrows against the alias-wide intersection, so a rollover drops the new field"
  end

  test "a plain index resolves no alias and observes its own mapping unchanged" do
    mappings = {
      "articles" => { "mappings" => { "properties" => {
        "title" => { "type" => "text" }, "status" => { "type" => "keyword" } } } }
    }

    adapter = ActiveSearch::StoreAdapters::Elasticsearch.new
    adapter.instance_variable_set(:@client, FakeClient.new(FakeIndices.new(mappings, {})))

    assert_equal %i[ title status ].sort,
      adapter.send(:observed_field_names, ActiveSearch.index(:articles)).map(&:to_sym).sort
  end

  test "an alias with no write index cannot say where a write lands, so it still intersects" do
    mappings = {
      "articles_old" => { "mappings" => { "properties" => {
        "title" => { "type" => "text" } } } },
      "articles_new" => { "mappings" => { "properties" => {
        "title" => { "type" => "text" }, "status" => { "type" => "keyword" } } } }
    }
    aliases = {
      "articles_old" => { "aliases" => { "articles" => {} } },
      "articles_new" => { "aliases" => { "articles" => {} } }
    }

    adapter = ActiveSearch::StoreAdapters::Elasticsearch.new
    adapter.instance_variable_set(:@client, FakeClient.new(FakeIndices.new(mappings, aliases)))

    assert_equal [ :title ], adapter.send(:observed_field_names, ActiveSearch.index(:articles)).map(&:to_sym)
  end
end
