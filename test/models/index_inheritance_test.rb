require "test_helper"

class IndexRegistryTest < ActiveSupport::TestCase
  test "index returns instance with correct name" do
    idx = ActiveSearch.index(:articles)
    assert_equal :articles, idx.name
  end

  test "index has correct search_fields" do
    idx = ActiveSearch.index(:articles)
    assert_includes idx.search_fields, :title
    assert_includes idx.search_fields, :content
  end

  test "index has correct filter_fields" do
    idx = ActiveSearch.index(:articles)
    assert_includes idx.filter_fields.keys, :account_id
    assert_includes idx.filter_fields.keys, :status
    assert_includes idx.filter_fields.keys, :published_at
    assert_includes idx.filter_fields.keys, :featured
  end

  test "index registry returns same instance" do
    idx1 = ActiveSearch.index(:articles)
    idx2 = ActiveSearch.index(:articles)
    assert_same idx1, idx2
  end

  test "unknown index raises ConfigurationError" do
    assert_raises(ActiveSearch::ConfigurationError) do
      ActiveSearch.index(:nonexistent)
    end
  end
end

class NamespacedIndexAdapterTest < ActiveSupport::TestCase
  searches :namespaced_tests

  test "namespaced index can add and search documents" do
    article = Article.create!(title: "Namespaced Test", content: "Testing index names", account_id: 1)
    ActiveSearch.index(:namespaced_tests).add(article)

    results = ActiveSearch.index(:namespaced_tests).search("Namespaced").results
    assert_equal 1, results.total
    assert_equal article, results.first
  end

  test "namespaced index can remove documents" do
    article = Article.create!(title: "Remove Namespaced", content: "Will be removed", account_id: 1)
    ActiveSearch.index(:namespaced_tests).add(article)

    results = ActiveSearch.index(:namespaced_tests).search("Remove Namespaced").results
    assert_equal 1, results.total

    ActiveSearch.index(:namespaced_tests).remove(article)
    results = ActiveSearch.index(:namespaced_tests).search("Remove Namespaced").results
    assert_equal 0, results.total
  end
end
