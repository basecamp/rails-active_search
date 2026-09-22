require "test_helper"

class InspectTest < ActiveSupport::TestCase
  def definition
    ActiveSearch::Index::Definition.new(fields: [
      ActiveSearch::Index::Field.new(:title, :text),
      ActiveSearch::Index::Field.new(:account_id, :integer)
    ])
  end

  test "a Document inspects as its id and data, not its definition" do
    document = ActiveSearch::Document.new(id: "60", data: { title: "Rails 8", account_id: 7 }, definition: definition)

    assert_equal %(#<ActiveSearch::Document id: "60", data: {title: "Rails 8", account_id: 7}>), document.inspect
    assert_not_includes document.inspect, "Definition"
    assert_not_includes document.inspect, "Field"
  end

  test "Results inspects as its total and page hit count, without hydrating or dumping internals" do
    results = ActiveSearch::Results.new([ { id: "1" }, { id: "2" } ], total: 42, definition: definition, source: nil)

    assert_equal "#<ActiveSearch::Results total: 42, hits: 2>", results.inspect
    assert_not_includes results.inspect, "Definition"
  end

  test "Results inspect counts the hits on this page, not the whole total" do
    results = ActiveSearch::Results.new([ { id: "3" } ], total: 42, definition: definition, source: nil, limit: 1, offset: 1)

    assert_equal "#<ActiveSearch::Results total: 42, hits: 1>", results.inspect
  end
end
