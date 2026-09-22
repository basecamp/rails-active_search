require "test_helper"

class SearchInputRobustnessTest < ActiveSupport::TestCase
  searches :articles

  setup do
    @article = Article.create!(title: "Contact page",
      content: "reach test@example.com about foo.bar today alpha beta", account_id: 1)
    ActiveSearch.index(:articles).add(@article)
    refresh
  end

  test "a plain word matches" do
    assert_results [ @article ], ActiveSearch.index(:articles).search("reach")
  end

  test "an email address is searchable input" do
    assert_results [ @article ], ActiveSearch.index(:articles).search("test@example.com")
  end

  test "a dotted term is searchable input" do
    assert_results [ @article ], ActiveSearch.index(:articles).search("foo.bar")
  end

  test "an unbalanced quote is literal text" do
    assert_results [ @article ], ActiveSearch.index(:articles).search('reach "today')
  end

  test "boolean-mode characters are literal terms" do
    skip "mysql boolean-mode leak; run SEARCH_ADAPTER=mysql" unless store_adapter_name == :mysql

    assert_results [ @article ], ActiveSearch.index(:articles).search("+alpha -beta")
  end

  test "a field-subset search executes" do
    skip "mysql MATCH column-list rule; run SEARCH_ADAPTER=mysql" unless store_adapter_name == :mysql

    assert_results [ @article ], ActiveSearch.index(:articles).search("Contact", fields: [ :title ])
  end

  private
    def refresh
      ActiveSearch.index(:articles).store.refresh(:articles)
    rescue StandardError
      nil
    end
end
