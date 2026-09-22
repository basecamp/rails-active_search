require "test_helper"

class DocumentArrayTest < ActiveSupport::TestCase
  searches :articles

  test "an array on a string field is refused at write time, not indexed as its inspect output" do
    article = Article.create!(title: "Arrayed", content: "content", account_id: 1)
    article.define_singleton_method(:status) { [ "a", "b" ] }

    error = assert_raises(ActiveSearch::DocumentError) { ActiveSearch.index(:articles).add(article) }

    assert_match(/must be a single value/, error.message)
  end

  test "an array filter is still an IN, cast element by element" do
    one = Article.create!(title: "Filtered one", content: "shared", account_id: 1, status: "published")
    two = Article.create!(title: "Filtered two", content: "shared", account_id: 1, status: "draft")
    [ one, two ].each { |a| ActiveSearch.index(:articles).add(a) }
    ActiveSearch.index(:articles).store.refresh(:articles) rescue nil

    assert_results [ one, two ], ActiveSearch.index(:articles).search("shared").filter(status: %w[published draft])
  end
end
