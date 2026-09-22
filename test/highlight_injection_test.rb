require "test_helper"

class HighlightInjectionTest < ActiveSupport::TestCase
  searches :articles

  test "literal marker text in a document does not become a live tag" do
    skip "adapter has no highlighting" unless supports_highlighting?

    article = Article.create!(title: "Payload", content: "payload <mark>evil</mark>", account_id: 1)
    ActiveSearch.index(:articles).add(article)
    begin
      ActiveSearch.index(:articles).store.refresh(:articles)
    rescue StandardError
      nil
    end

    fragment = Article.search("payload").highlight(true).results.first.hit.highlight(:content).to_s

    assert_includes fragment, "<mark>payload</mark>"

    assert_not_includes fragment, "<mark>evil</mark>"
    assert_includes fragment, "&lt;mark&gt;evil&lt;/mark&gt;"
  end
end
