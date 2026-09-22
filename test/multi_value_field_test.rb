require "test_helper"

class MultiValueFieldTest < ActiveSupport::TestCase
  searches :articles

  def field(name, type, **options)
    ActiveSearch::Index::Field.new(name, type, **options)
  end

  def definition_of(*fields)
    ActiveSearch::Index::Definition.new(fields: fields)
  end

  def document(definition, data)
    ActiveSearch::Document.new(id: "1", data: data, definition: definition)
  end

  test "a field is single-valued unless it says otherwise" do
    assert_not field(:account_id, :integer).multiple?
    assert field(:folder_ids, :integer, multiple: true).multiple?
  end

  test "integer, string and datetime fields can hold many values" do
    %i[integer string datetime].each do |type|
      assert field(:whatever, type, multiple: true).multiple?, "#{type} should accept multiple:"
    end
  end

  test "the other types refuse to hold many values, rather than doing so unfilterably" do
    %i[text float boolean date].each do |type|
      error = assert_raises(ActiveSearch::ConfigurationError, "#{type} should refuse multiple:") do
        field(:whatever, type, multiple: true)
      end

      assert_match(/cannot be multiple:/, error.message)
    end
  end

  test "a range on a field that holds many values follows the store capability" do
    relation = ActiveSearch.index(:topics)

    if relation.capabilities.supports_collection_ranges?
      assert_nothing_raised { relation.filter(folder_ids: 4..9) }
    else
      error = assert_raises(ActiveSearch::UnsupportedOperationError) { relation.filter(folder_ids: 4..9) }
      assert_match(/does not support a range/, error.message)
    end
  end

  test "an unbounded range on a field that holds many values drops instead of raising" do
    relation = ActiveSearch.index(:topics).filter(folder_ids: nil..nil)

    assert_empty query_context_for(relation).all_conditions.to_a
  end

  test "a field that holds many values cannot be sorted on" do
    error = assert_raises(ActiveSearch::QueryError) { ActiveSearch.index(:topics).sort(folder_ids: :asc) }

    assert_match(/holds many values and cannot be sorted on/, error.message)
  end

  test "a single-value field on the same index is still sortable" do
    assert_nothing_raised { ActiveSearch.index(:topics).sort(account_id: :asc) }
  end

  test "a range is still fine on a single-value field of the same type" do
    assert_nothing_raised { ActiveSearch.index(:topics).filter(account_id: 4..9) }
  end

  test "each element casts through the element type" do
    folder_ids = field(:folder_ids, :integer, multiple: true)

    assert_equal [ 1, 2, 3 ], folder_ids.document_caster.cast([ "1", 2, 3.0 ])
  end

  test "a bare value is one element" do
    assert_equal [ 7 ], field(:folder_ids, :integer, multiple: true).document_caster.cast(7)
  end

  test "order and duplicates survive" do
    folder_ids = field(:folder_ids, :integer, multiple: true)

    assert_equal [ 3, 1, 3 ], folder_ids.document_caster.cast([ 3, 1, 3 ])
  end

  test "an empty collection is kept, because no values is not the same as no field" do
    assert_equal [], field(:folder_ids, :integer, multiple: true).document_caster.cast([])
  end

  test "a nil element is refused rather than indexed as an absence" do
    error = assert_raises(ActiveSearch::Type::Invalid) do
      field(:folder_ids, :integer, multiple: true).document_caster.cast([ 1, nil ])
    end

    assert_match(/must not contain nil/, error.message)
  end

  test "a Hash is refused, because a collection of pairs is not a collection of values" do
    error = assert_raises(ActiveSearch::Type::Invalid) do
      field(:folder_ids, :integer, multiple: true).document_caster.cast({ a: 1 })
    end

    assert_match(/must be a collection of single values/, error.message)
  end

  test "an element that will not cast raises through the field, naming it" do
    definition = definition_of(field(:folder_ids, :integer, multiple: true))

    error = assert_raises(ActiveSearch::DocumentError) { document(definition, folder_ids: [ 1, 2**64 ]) }

    assert_match(/value for 'folder_ids'/, error.message)
    assert_match(/out of range/, error.message)
  end

  test "a single-value field still refuses a collection" do
    definition = definition_of(field(:status, :string))

    error = assert_raises(ActiveSearch::DocumentError) { document(definition, status: %w[a b]) }

    assert_match(/must be a single value/, error.message)
  end

  test "a filter value casts one element at a time, even on a multiple: field" do
    folder_ids = field(:folder_ids, :integer, multiple: true)

    assert_equal 1, folder_ids.caster.cast("1")
    assert_equal 1, folder_ids.boundary_caster.cast("1")
  end

  test "a document keeps the collection whole" do
    definition = definition_of(field(:folder_ids, :integer, multiple: true))

    assert_equal [ 1, 2 ], document(definition, folder_ids: [ 1, 2 ]).data[:folder_ids]
  end

  test "a nil collection is absent, not empty" do
    definition = definition_of(field(:folder_ids, :integer, multiple: true))
    doc = document(definition, folder_ids: nil)

    assert_not doc.data.key?(:folder_ids)
    assert_includes doc.absent_fields, :folder_ids
  end
end
