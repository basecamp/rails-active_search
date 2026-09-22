require "test_helper"

# Driven on a directly built adapter with no live server, so every suite covers these paths
# rather than only the elasticsearch run.
class ElasticContractTest < ActiveSupport::TestCase
  setup do
    @store = ActiveSearch::StoreAdapters::Elasticsearch.new
    @index = ActiveSearch.index(:articles)
  end

  test "an ES7 integer total parses as an exact count" do
    parsed = @store.send(:parse_response, { "hits" => { "total" => 7, "hits" => [] } }, nil, nil)

    assert_equal [ 7, :equal ], parsed.values_at(:total, :total_relation)
  end

  test "a timed out delete_by_query raises instead of reporting the partial count" do
    swap_client(deleting_client("deleted" => 3, "timed_out" => true, "failures" => []))

    error = assert_raises(ActiveSearch::AdapterError) { remove_all }
    assert_match(/timed out after removing 3/, error.message)
  end

  test "delete_by_query failures raise naming the failure" do
    swap_client(deleting_client("deleted" => 3, "timed_out" => false,
      "failures" => [ { "id" => "9", "cause" => { "reason" => "version conflict" } } ]))

    error = assert_raises(ActiveSearch::AdapterError) { remove_all }
    assert_match(/failed on 1 of its matches/, error.message)
    assert_match(/version conflict/, error.message)
  end

  test "a clean delete_by_query still answers the count" do
    swap_client(deleting_client("deleted" => 3, "timed_out" => false, "failures" => []))

    assert_equal 3, remove_all
  end

  test "drop_index translates a transport failure instead of leaking it" do
    transport_error = ActiveSearch::StoreAdapters::Elasticsearch::CLIENT_ERRORS.fetch(0)
    indices = Class.new { define_method(:delete) { |**| raise transport_error, "boom" } }
    swap_client(Struct.new(:indices).new(indices.new))

    assert_raises(ActiveSearch::AdapterError) { @store.drop_index(@index) }
  end

  private
    def swap_client(fake)
      @store.instance_variable_set(:@client, fake)
    end

    def deleting_client(response)
      Class.new { define_method(:delete_by_query) { |**| response } }.new
    end

    def remove_all
      @store.remove_by_filter(@index, query_context_for(@index.search("x")))
    end
end
