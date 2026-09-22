require "test_helper"

class GuardLiteralTest < ActiveSupport::TestCase
  searches :articles

  class NeverIndexedArticle < ApplicationRecord
    self.table_name = "articles"
    include ActiveSearch::Indexable
    has_search index: :articles, if: false, async: false
  end

  class AddDisabledArticle < ApplicationRecord
    self.table_name = "articles"
    include ActiveSearch::Indexable
    has_search index: :articles, add_if: false, if: :shared_guard, async: false

    def shared_guard
      true
    end
  end

  class SubGuarded < GuardedArticle
  end

  test "a literal if: false guard never indexes" do
    NeverIndexedArticle.create!(title: "GuardLiteralNever", content: "text", account_id: 1)
    assert_results [], ActiveSearch.index(:articles).search("GuardLiteralNever")
  end

  test "a literal add_if: false disables add instead of deferring to the shared :if" do
    AddDisabledArticle.create!(title: "GuardLiteralAdd", content: "text", account_id: 1)
    assert_results [], ActiveSearch.index(:articles).search("GuardLiteralAdd")
  end

  test "suppress_indexing on a base class covers its subclasses" do
    GuardedArticle.suppress_indexing do
      assert SubGuarded.indexing_suppressed?,
        "a subclass saved inside the base class's suppress_indexing block still indexes"
    end
  end
end
