require "test_helper"

# Driven on a directly built adapter with no live server, so every suite covers this path. A
# non-exact count cannot be produced live against a small core: Solr only stops counting when
# minExactCount is beaten, which needs more segments than a test index has.
class SolrContractTest < ActiveSupport::TestCase
  setup do
    @store = ActiveSearch::StoreAdapters::Solr.new
  end

  test "an approximate total is reported as a lower bound rather than an exact count" do
    approximate = parse(response_with("numFound" => 100, "numFoundExact" => false))
    counted = parse(response_with("numFound" => 42, "numFoundExact" => true))
    legacy = parse(response_with("numFound" => 42))

    assert_equal [ 100, :lower_bound ], approximate.values_at(:total, :total_relation)
    assert_equal [ 42, :equal ], counted.values_at(:total, :total_relation)
    assert_equal [ 42, :equal ], legacy.values_at(:total, :total_relation)
  end

  test "an approximate total is not a partial page" do
    approximate = parse(response_with("numFound" => 100, "numFoundExact" => false))

    assert_equal false, approximate[:partial_results]
  end

  private
    def parse(response)
      @store.send(:parse_response, response, nil, [])
    end

    def response_with(body)
      { "responseHeader" => { "QTime" => 1 }, "response" => { "docs" => [] }.merge(body) }
    end
end
