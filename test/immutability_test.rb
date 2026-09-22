require "test_helper"

class ImmutabilityTest < ActiveSupport::TestCase
  searches :articles

  def relation
    ActiveSearch.index(:articles).all
  end

  def context_for(rel)
    rel.send(:query_context)
  end

  test "mutating a filter array after the fact does not change the query" do
    statuses = [ "published" ]
    query = relation.filter(status: statuses)

    statuses << "draft"

    values = context_for(query).all_conditions.for_field(:status).first.value
    assert_equal [ "published" ], values
  end

  test "mutating a filter string after the fact does not change the query" do
    status = +"published"
    query = relation.filter(status: status)

    status << " and more"

    assert_equal "published", context_for(query).all_conditions.for_field(:status).first.value
  end

  test "mutating a search field list after the fact does not change the query" do
    fields = [ :title ]
    query = relation.search("ruby", fields: fields)

    fields << :content

    assert_equal [ :title ], context_for(query).fields
  end

  test "mutating a hit field list after the fact does not change the query" do
    fields = [ :title ]
    query = relation.hit_fields(*fields)

    fields << :content

    assert_equal [ :title ], context_for(query).hit_fields
  end

  test "a query holds its own copies of every caller value" do
    fields = [ +"title" ]
    values = [ +"a", +"b" ]
    query = relation.search("ruby", fields: fields).filter(status: values)
    context = context_for(query)

    assert_not_same fields, context.fields
    assert_not_same values, context.all_conditions.first.value

    fields.first << " OR evil"
    values << "c"

    assert_equal [ :title ], context.fields
    assert_equal [ "a", "b" ], context.all_conditions.first.value
  end

  test "filtering by a Time does not convert the caller's Time to UTC" do
    tokyo = Time.new(2024, 1, 1, 12, 0, 0, "+09:00")

    relation.filter(published_at: tokyo).results

    assert_equal 32_400, tokyo.utc_offset, "the caller's Time was converted in place"
    assert_not_predicate tokyo, :utc?
  end

  test "the context itself is frozen" do
    context = context_for(relation.search("ruby").sort(published_at: :desc))

    assert_predicate context, :frozen?
    assert_raises(FrozenError) { context.instance_variable_set(:@query, "other") }
  end

  test "query_context is not a public reader" do
    assert_not relation.respond_to?(:query_context),
      "a caller must not be able to reach into a relation's normalized state"
    assert_includes relation.private_methods, :query_context
  end

  test "a caller's own array is not frozen by passing it in" do
    statuses = [ "published" ]
    relation.filter(status: statuses)

    assert_not statuses.frozen?, "freezing a caller's array would be a side effect on their object"
  end

  test "a caller's own string is not frozen by passing it in" do
    status = +"published"
    relation.filter(status: status)

    assert_not status.frozen?
  end

  test "a caller's own field list is not frozen by passing it in" do
    fields = [ :title ]
    relation.hit_fields(*fields)

    assert_not fields.frozen?
  end

  test "a String sort field the caller still holds is not frozen" do
    field = +"published_at"
    ActiveSearch.index(:articles).sort(field)

    assert_not field.frozen?, "the caller's String was frozen by being used as a sort field"
    assert_nothing_raised { field << "_at_all" }
  end

  test "a capability list is a copy of what the adapter passed" do
    units = [ :words ]
    capabilities = ActiveSearch::Capabilities.new(highlight_snippet_units: units)

    assert_nothing_raised { units << :characters }

    assert capabilities.supports_snippet_unit?(:words)
    assert_not capabilities.supports_snippet_unit?(:characters)
  end
end
