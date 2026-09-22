require "test_helper"

class FieldTest < ActiveSupport::TestCase
  test "accepts valid types" do
    %i[text string integer float boolean datetime date].each do |type|
      field = ActiveSearch::Index::Field.new(:field_name, type)
      assert_equal type, field.type
    end
  end

  test "raises on invalid type" do
    assert_raises ActiveSearch::ConfigurationError do
      ActiveSearch::Index::Field.new(:field_name, :invalid)
    end
  end

  test "text field is searchable" do
    field = ActiveSearch::Index::Field.new(:title, :text)
    assert field.searchable?
  end

  test "text field is not filterable" do
    field = ActiveSearch::Index::Field.new(:title, :text)
    refute field.filterable?
  end

  test "string field is not searchable" do
    field = ActiveSearch::Index::Field.new(:status, :string)
    refute field.searchable?
  end

  test "string field is always filterable" do
    field = ActiveSearch::Index::Field.new(:status, :string)
    assert field.filterable?
  end

  test "integer field is filterable" do
    field = ActiveSearch::Index::Field.new(:count, :integer)
    refute field.searchable?
    assert field.filterable?
  end

  test "float field is filterable" do
    field = ActiveSearch::Index::Field.new(:price, :float)
    refute field.searchable?
    assert field.filterable?
  end

  test "boolean field is filterable" do
    field = ActiveSearch::Index::Field.new(:featured, :boolean)
    refute field.searchable?
    assert field.filterable?
  end

  test "datetime field is filterable" do
    field = ActiveSearch::Index::Field.new(:published_at, :datetime)
    refute field.searchable?
    assert field.filterable?
  end

  test "date field is filterable" do
    field = ActiveSearch::Index::Field.new(:published_on, :date)
    refute field.searchable?
    assert field.filterable?
  end
end

class DefinitionTest < ActiveSupport::TestCase
  Field = ActiveSearch::Index::Field

  def build_definition(&block)
    fields = []
    block.call(fields)
    ActiveSearch::Index::Definition.new(fields: fields)
  end

  test "search_fields returns text fields" do
    definition = build_definition do |f|
      f << Field.new(:title, :text)
      f << Field.new(:content, :text)
      f << Field.new(:status, :string)
      f << Field.new(:count, :integer)
    end

    assert_equal [ :title, :content ], definition.search_fields
  end

  test "searchable? returns true for searchable fields" do
    definition = build_definition do |f|
      f << Field.new(:title, :text)
      f << Field.new(:status, :string)
    end

    assert definition.searchable?(:title)
    refute definition.searchable?(:status)
  end

  test "filterable? returns true for filterable fields" do
    definition = build_definition do |f|
      f << Field.new(:title, :text)
      f << Field.new(:status, :string)
      f << Field.new(:count, :integer)
    end

    refute definition.filterable?(:title)
    assert definition.filterable?(:status)
    assert definition.filterable?(:count)
  end

  test "validation helpers return falsy for unknown fields" do
    definition = build_definition do |f|
      f << Field.new(:title, :text)
    end

    refute definition.searchable?(:unknown)
    refute definition.filterable?(:unknown)
  end

  test "bracket access returns field by name" do
    definition = build_definition do |f|
      f << Field.new(:title, :text)
      f << Field.new(:status, :string)
    end

    assert_equal :text, definition[:title].type
    assert_equal :string, definition[:status].type
  end

  test "bracket access accepts string or symbol" do
    definition = build_definition do |f|
      f << Field.new(:title, :text)
    end

    assert_equal definition[:title], definition["title"]
  end

  test "bracket access returns nil for unknown field" do
    definition = build_definition do |f|
      f << Field.new(:title, :text)
    end

    assert_nil definition[:unknown]
  end

  test "field_names returns unique names" do
    definition = build_definition do |f|
      f << Field.new(:title, :text)
      f << Field.new(:status, :string)
    end

    assert_equal [ :title, :status ], definition.field_names
  end

  test "empty definition has empty search_fields" do
    definition = ActiveSearch::Index::Definition.new(fields: [])

    assert_empty definition.search_fields
  end
end

class DefinitionIndexIntegrationTest < ActiveSupport::TestCase
  test "article index has correct search_fields" do
    definition = ActiveSearch.index(:articles).definition
    assert_equal [ :title, :content ], definition.search_fields
  end

  test "article index definition validates filterable fields" do
    definition = ActiveSearch.index(:articles).definition
    assert definition.filterable?(:account_id)
    assert definition.filterable?(:status)
    assert definition.filterable?(:published_at)
    assert definition.filterable?(:featured)
    refute definition.filterable?(:title)
  end
end

class DefinitionValidationTest < ActiveSupport::TestCase
  searches :articles

  test "filter raises on non-filterable field" do
    error = assert_raises ActiveSearch::QueryError do
      ActiveSearch.index(:articles).filter(title: "test")
    end
    assert_match(/not filterable/, error.message)
    assert_match(/title/, error.message)
  end

  test "filter on filterable field returns matching records" do
    article1 = Article.create!(title: "Filter Test", content: "Content", account_id: 1)
    article2 = Article.create!(title: "Filter Test", content: "Content", account_id: 2)
    [ article1, article2 ].each { |a| ActiveSearch.index(:articles).add(a) }

    results = ActiveSearch.index(:articles).filter(account_id: 1).search("Filter Test").results
    assert_equal 1, results.total
    assert_equal article1.id, results.first.id
  end

  test "sort raises on non-filterable field" do
    error = assert_raises ActiveSearch::QueryError do
      ActiveSearch.index(:articles).sort(:title)
    end
    assert_match(/not sortable/, error.message)
    assert_match(/title/, error.message)
  end

  test "a datetime sort puts oldest first ascending and newest first descending" do
    old_time = 5.days.ago
    new_time = 1.day.ago
    article1 = Article.create!(title: "Sort Test", content: "Content", account_id: 1, published_at: old_time)
    article2 = Article.create!(title: "Sort Test", content: "Content", account_id: 1, published_at: new_time)
    [ article1, article2 ].each { |a| ActiveSearch.index(:articles).add(a) }

    asc_results = ActiveSearch.index(:articles).search("Sort Test").sort(published_at: :asc).results
    assert_equal [ article1.id, article2.id ], asc_results.map(&:id)

    desc_results = ActiveSearch.index(:articles).search("Sort Test").sort(published_at: :desc).results
    assert_equal [ article2.id, article1.id ], desc_results.map(&:id)
  end

  test "sort by Score ranks by relevance" do
    article1 = Article.create!(title: "Programming", content: "Learn Ruby", account_id: 1)
    article2 = Article.create!(title: "Ruby Ruby Ruby", content: "Ruby is great", account_id: 1)
    [ article1, article2 ].each { |a| ActiveSearch.index(:articles).add(a) }

    results = ActiveSearch.index(:articles).search("Ruby").sort_by_relevance.results
    assert_equal 2, results.total
    assert_equal article2.id, results.first.id
  end

  test "search with single field only matches that field" do
    article1 = Article.create!(title: "Ruby Programming", content: "Learn to code", account_id: 1)
    article2 = Article.create!(title: "Programming Guide", content: "Ruby is great", account_id: 1)
    [ article1, article2 ].each { |a| ActiveSearch.index(:articles).add(a) }

    results = ActiveSearch.index(:articles).search("Ruby", fields: :title).results
    assert_equal 1, results.total
    assert_equal article1.id, results.first.id
  end

  test "search with multiple fields matches any field" do
    article1 = Article.create!(title: "Ruby Programming", content: "Learn to code", account_id: 1)
    article2 = Article.create!(title: "Programming Guide", content: "Ruby is great", account_id: 1)
    [ article1, article2 ].each { |a| ActiveSearch.index(:articles).add(a) }

    results = ActiveSearch.index(:articles).search("Ruby", fields: [ :title, :content ]).results
    assert_equal 2, results.total
  end

  test "field restriction persists through chaining" do
    article1 = Article.create!(title: "Ruby Programming", content: "Learn to code", account_id: 1)
    article2 = Article.create!(title: "Programming Guide", content: "Ruby is great", account_id: 1)
    [ article1, article2 ].each { |a| ActiveSearch.index(:articles).add(a) }

    results = ActiveSearch.index(:articles).search("Ruby", fields: :title).filter(account_id: 1).limit(10).results
    assert_equal 1, results.total
    assert_equal article1.id, results.first.id
  end
end
