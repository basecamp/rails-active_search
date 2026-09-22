require "test_helper"

class DateFieldTest < ActiveSupport::TestCase
  searches :articles

  def dated_article(date, title:)
    Article.create!(title: title, content: "Shared", account_id: 1,
      published_at: date.to_time(:utc)).tap { |article| ActiveSearch.index(:articles).add(article) }
  end

  test "a date field reads back as a Date" do
    dated_article(Date.new(2026, 2, 3), title: "Dated")

    fields = ActiveSearch.index(:articles).search("Dated").results.first.hit.fields

    assert_equal Date.new(2026, 2, 3), fields[:published_on]
    assert_instance_of Date, fields[:published_on]
  end

  test "a date equality filter matches the stored day and no other" do
    article = dated_article(Date.new(2026, 2, 3), title: "Sought")
    dated_article(Date.new(2026, 2, 4), title: "Sought Too")

    assert_results article, ActiveSearch.index(:articles).search("Sought")
      .filter(published_on: Date.new(2026, 2, 3))
    assert_results [], ActiveSearch.index(:articles).search("Sought")
      .filter(published_on: Date.new(2026, 2, 5))
  end

  test "a date range filter selects by day, endpoints included" do
    inside = dated_article(Date.new(2026, 2, 3), title: "Ranged")
    edge = dated_article(Date.new(2026, 2, 5), title: "Ranged Edge")
    dated_article(Date.new(2026, 2, 9), title: "Ranged Outside")

    assert_results [ inside, edge ], ActiveSearch.index(:articles).search("Ranged")
      .filter(published_on: Date.new(2026, 2, 1)..Date.new(2026, 2, 5))
  end

  test "the date caster runs only where the declaration says date" do
    definition = ActiveSearch.index(:articles).definition
    results = ActiveSearch::Results.new([], total: 0, definition: definition, source: nil,
      type_casters: { date: ActiveSearch::Type::EpochSecondsDate.new })

    epoch = Date.new(2026, 2, 3).to_time(:utc).to_i
    casted = results.send(:cast_fields,
      { status: "2026-02-03", account_id: epoch, published_on: epoch }, definition)

    assert_equal "2026-02-03", casted[:status], "a string-declared field must stay a String"
    assert_equal epoch, casted[:account_id], "an integer-declared field must stay an Integer"
    assert_equal Date.new(2026, 2, 3), casted[:published_on]
  end
end
