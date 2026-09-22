require "test_helper"

class RawTypesTest < ActiveSupport::TestCase
  searches :articles, :products

  test "search_fields returns correct types for text, integer, string, datetime, boolean" do
    article = Article.create!(
      title: "Type Test",
      content: "Testing types",
      account_id: 42,
      status: "published",
      published_at: Time.utc(2024, 1, 15, 10, 30),
      featured: true
    )

    idx = ActiveSearch.index(:articles)
    store = idx.store

    ActiveSearch.index(:articles).add(article)
    store.refresh(idx.name) if store.respond_to?(:refresh)

    result = idx.search("Type Test").hit_fields(:title, :account_id, :status, :published_at, :featured).results.first
    fields = result.hit.fields

    assert_kind_of String, fields[:title], "title (text) should be String"
    assert_kind_of Integer, fields[:account_id], "account_id (integer) should be Integer"
    assert_kind_of String, fields[:status], "status (string) should be String"
    assert_kind_of Time, fields[:published_at], "published_at (datetime) should be Time"
    assert_includes [ TrueClass, FalseClass ], fields[:featured].class, "featured (boolean) should be Boolean"
    assert_equal true, fields[:featured]

    article.destroy
  end

  test "search_fields returns correct type for float" do
    skip "ProductDocument not defined for database adapters" if database_adapter?

    product = Product.create!(
      name: "Float Test",
      description: "Testing float",
      price: 19.99,
      category: "test"
    )

    idx = ActiveSearch.index(:products)
    store = idx.store

    ActiveSearch.index(:products).add(product)
    store.refresh(idx.name) if store.respond_to?(:refresh)

    result = idx.search("Float Test").hit_fields(:name, :price).results.first
    fields = result.hit.fields

    assert_kind_of String, fields[:name], "name (text) should be String"
    assert_kind_of Float, fields[:price], "price (float) should be Float"
    assert_in_delta 19.99, fields[:price], 0.001

    product.destroy
  end

  private
    def database_adapter?
    %w[sqlite postgresql mysql].include?(ENV.fetch("SEARCH_ADAPTER", "sqlite"))
  end
end
