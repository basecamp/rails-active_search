require "test_helper"

class FieldPolicyTest < ActiveSupport::TestCase
  searches :articles, :products

  def index
    ActiveSearch.index(:articles)
  end

  def products
    ActiveSearch.index(:products)
  end

  def subfields?
    capabilities.supports_search_subfields?
  end

  def string_fields?
    capabilities.supports_search_string_fields?
  end

  test "an index exposes its store's capabilities" do
    assert_same index.store.capabilities, index.capabilities
  end

  test "the capability set is frozen" do
    assert_predicate index.capabilities, :frozen?
  end

  test "subfield and string-field support are declared only by elastic adapters" do
    expected = %i[elasticsearch opensearch].include?(store_adapter_name)

    assert_equal expected, index.capabilities.supports_search_subfields?
    assert_equal expected, index.capabilities.supports_search_string_fields?
  end

  test "default search targets all and only declared text fields" do
    assert_equal [ :title, :content ], index.definition.search_fields
  end

  test "a string-only field is not part of default search" do
    assert_not_includes index.definition.search_fields, :status
  end

  test "a declared text field is always selectable" do
    assert_nothing_raised { index.search("ruby", fields: [ :title, :content ]) }
  end

  test "an undeclared field is rejected on every adapter" do
    assert_raises(ActiveSearch::QueryError) { index.search("ruby", fields: [ :nonexistent ]) }
  end

  test "a string-only field is selectable only where the adapter supports it" do
    if string_fields?
      assert_nothing_raised { index.search("ruby", fields: [ :status ]) }
    else
      error = assert_raises(ActiveSearch::UnsupportedOperationError) { index.search("ruby", fields: [ :status ]) }
      assert_match(/does not support searching a string field/, error.message)
      assert_match(/Use filter for exact matching/, error.message)
    end
  end

  test "the string-field refusal is rescuable as a QueryError" do
    skip "adapter supports string-field search" if string_fields?

    assert_raises(ActiveSearch::QueryError) { index.search("ruby", fields: [ :status ]) }
  end

  test "a subfield of a text field is selectable only where the adapter supports it" do
    if subfields?
      assert_nothing_raised { index.search("ruby", fields: [ "title.en" ]) }
    else
      error = assert_raises(ActiveSearch::UnsupportedOperationError) { index.search("ruby", fields: [ "title.en" ]) }
      assert_match(/does not support search subfields/, error.message)
    end
  end

  test "a subfield whose base is not a text field is rejected on every adapter" do
    error = assert_raises(ActiveSearch::QueryError) { index.search("ruby", fields: [ "status.exact" ]) }
    assert_match(/base must be a declared text field/, error.message)
  end

  test "a subfield of an undeclared base is rejected on every adapter" do
    assert_raises(ActiveSearch::QueryError) { index.search("ruby", fields: [ "nonexistent.en" ]) }
  end

  test "malformed field names are rejected on every adapter" do
    [ "*", "title^2", "title en", "title[0]", "title.en.us", "title.", ".title", "title;drop" ].each do |name|
      assert_raises(ActiveSearch::QueryError, "expected #{name.inspect} to be rejected") do
        index.search("ruby", fields: [ name ])
      end
    end
  end

  test "a text field is searchable and not filterable" do
    assert_includes products.definition.search_fields, :category
    assert_nothing_raised { products.search("chair", fields: [ :category ]) }

    assert_raises(ActiveSearch::QueryError) { products.filter(category: "seating") }
    assert_raises(ActiveSearch::QueryError) { products.sort(category: :asc) }
  end

  test "a subfield of a text field needs adapter support" do
    if subfields?
      assert_nothing_raised { products.search("chair", fields: [ "category.exact" ]) }
    else
      assert_raises(ActiveSearch::UnsupportedOperationError) { products.search("chair", fields: [ "category.exact" ]) }
    end
  end

  test "a string-only field cannot be highlighted on any adapter" do
    skip "adapter has no highlighting" unless supports_highlighting?

    error = assert_raises(ActiveSearch::QueryError) { index.search("ruby").highlight(status: true) }
    assert_match(/not highlightable/, error.message)
  end

  test "a text field is highlightable" do
    skip "adapter has no highlighting" unless supports_highlighting?

    assert_nothing_raised { index.search("ruby").highlight(title: true) }
  end

  test "a subfield is highlightable only where the adapter supports subfields" do
    skip "adapter has no highlighting" unless supports_highlighting?

    if subfields?
      assert_nothing_raised { index.search("ruby").highlight("title.en" => true) }
    else
      assert_raises(ActiveSearch::UnsupportedOperationError) { index.search("ruby").highlight("title.en" => true) }
    end
  end
end
