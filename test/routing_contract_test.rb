require "test_helper"

class RoutingContractTest < ActiveSupport::TestCase
  searches :records

  def index
    ActiveSearch.index(:records)
  end

  setup do
    Post
    Page
    @mine = Post.create!(headline: "Routed Document", body: "Content", account_id: 1)
    @theirs = Post.create!(headline: "Routed Document", body: "Content", account_id: 2)

    [ @mine, @theirs ].each { |record| index.add(record) }
  end

  test "the index declares a routing field" do
    assert_equal :account_id, index.route_by
  end

  test "a routed query returns only its own route's documents" do
    assert_results [ @mine, @theirs ], index.search("Routed Document"),
      "control: both accounts' documents are indexed and findable unrouted"

    assert_results @mine, index.search("Routed Document").filter(account_id: 1)
    assert_results @theirs, index.search("Routed Document").filter(account_id: 2)
  end

  test "an unrouted query still finds documents written with routing" do
    assert_results [ @mine, @theirs ], index.search("Routed Document")
  end

  test "a removal reaches the same route as the write" do
    index.remove(@mine)

    assert_results @theirs, index.search("Routed Document")
  end

  test "a batch write routes each document to its own route" do
    third = Post.create!(headline: "Routed Document", body: "Content", account_id: 3)

    index.batch { |batch| batch.add(third) }

    assert_results third, index.search("Routed Document").filter(account_id: 3)
  end

  test "filters that cannot all hold raise rather than returning a quiet empty page" do
    assert_raises(ActiveSearch::QueryError) do
      index.search("Routed Document").filter(account_id: 1).filter(account_id: 2).results
    end
  end

  test "the two routing values under test occupy different shards" do
    skip "only the Elastic family routes" unless shards_by_routing

    assert_operator shard_count, :>, 1, "a single-shard index cannot show what routing does"
    assert_not_equal shards_by_routing["1"], shards_by_routing["2"],
      "accounts 1 and 2 share a shard, so a union assertion holds whatever routing does"
  end

  test "a search routed to one value cannot see another value's shard" do
    skip "only the Elastic family routes" unless shards_by_routing

    assert_equal [ 1 ], raw_search_accounts(routing: "1")
    assert_equal [ 1, 2 ], raw_search_accounts(routing: nil),
      "control: both documents are there to be found when nothing narrows the search"
  end

  test "a list on the routing field returns every match across those shards" do
    first = Post.create!(headline: "Unioned across shards one", body: "Content", account_id: 1)
    second = Post.create!(headline: "Unioned across shards two", body: "Content", account_id: 2)
    [ first, second ].each { |post| index.add(post) }

    assert_results [ first, second ], index.search("Unioned").filter(account_id: [ 1, 2 ])
  end

  test "results and to_native_query resolve routing identically" do
    relation = index.search("Routed Document").filter(account_id: 1)

    assert_nothing_raised { relation.to_native_query }
    assert_results @mine, relation

    unroutable = index.search("Routed Document").filter(account_id: 1).filter(account_id: 2)
    assert_raises(ActiveSearch::QueryError) { unroutable.to_native_query }
    assert_raises(ActiveSearch::QueryError) { unroutable.results }
  end

  test "model scoping does not disturb routing" do
    page = Page.create!(title: "Routed Document", content: "Content", account_id: 1)
    index.add(page)

    assert_results @mine, Post.search("Routed Document").filter(account_id: 1)
    assert_results page, Page.search("Routed Document").filter(account_id: 1)
  end

  private
    def elastic_client
      index.store.client if index.store.respond_to?(:client) && index.store.class.name =~ /Elastic|Opensearch/
    end

    def shards_by_routing
      client = elastic_client
      return nil unless client

      %w[ 1 2 ].index_with do |routing|
        client.perform_request("GET", "#{index.index_name}/_search_shards", routing: routing)
          .body["shards"].flatten.map { |shard| shard["shard"] }.sort
      end
    end

    def shard_count
      elastic_client.perform_request("GET", "#{index.index_name}/_search_shards")
        .body["shards"].size
    end

    def raw_search_accounts(routing:)
      params = { size: 100 }
      params[:routing] = routing if routing
      elastic_client.perform_request("GET", "#{index.index_name}/_search", params,
        { query: { match: { title: "Routed" } } })
        .body.dig("hits", "hits").map { |hit| hit.dig("_source", "account_id") }.sort
    end
end
