require "test_helper"

class RedisProtocolTest < ActiveSupport::TestCase
  def parse(response)
    ActiveSearch::StoreAdapters::RedisSearch.allocate
      .send(:parse_response, response, nil, [], "articles")
  end

  test "parses a RESP2 flat array reply" do
    result = parse([ 1, "articles:Article/7", "0.8", [ "title", "ruby" ] ])

    assert_equal 1, result[:total]
    assert_equal "gid://dummy/Article/7", result[:results].first[:id]
    assert_in_delta 0.8, result[:results].first[:score]
    assert_equal({ title: "ruby" }, result[:results].first[:fields])
  end

  test "parses a RESP3 map reply" do
    result = parse({
      "total_results" => 1,
      "results" => [
        { "id" => "articles:Article/7", "score" => 0.8, "extra_attributes" => { "title" => "ruby" } }
      ]
    })

    assert_equal 1, result[:total]
    assert_equal "gid://dummy/Article/7", result[:results].first[:id]
    assert_in_delta 0.8, result[:results].first[:score]
    assert_equal({ title: "ruby" }, result[:results].first[:fields])
  end
end
