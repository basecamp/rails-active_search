require "test_helper"

class HitFieldProjectionTest < ActiveSupport::TestCase
  searches :topics

  WRITER_NARROWS_TO_STORE = {
    sqlite: "names its columns", mysql: "names its columns", postgresql: "names its columns",
    manticore: "gets a table holding only declared columns, so the write is refused",
    elasticsearch: "narrows the write to the observed mapping",
    opensearch: "narrows the write to the observed mapping",
    typesense: "narrows the write to the observed collection",
    solr: "narrows the write to the observed schema"
  }.freeze

  setup do
    @index = ActiveSearch.index(:topics)
  end

  test "an attribute the schema does not declare is not a caller-visible field" do
    store_stray_attribute

    assert_includes without_projection { searched_fields }.keys, :stray_attribute,
      "#{store_adapter_name} did not store the undeclared attribute, so this test proves nothing"

    fields = searched_fields

    assert_not_includes fields.keys, :stray_attribute
    assert_equal [], fields.keys - @index.definition.field_names
  end

  test "a declared field still arrives" do
    store_stray_attribute

    assert_equal "Planning", searched_fields[:subject]
  end

  test "a native block asking for an undeclared attribute still does not get it" do
    skip "_source is Elasticsearch's" unless %i[elasticsearch opensearch].include?(store_adapter_name)
    store_stray_attribute

    asking = @index.search("Planning").native do |request|
      request[:_source] = %w[ subject stray_attribute ]
      request
    end

    assert_includes without_projection { asking.results.first.hit.fields }.keys, :stray_attribute,
      "the native block did not make the store return it, so this test proves nothing"

    fields = asking.results.first.hit.fields

    assert_not_includes fields.keys, :stray_attribute
    assert_equal "Planning", fields[:subject]
  end

  test "string-keyed fields from another adapter are projected rather than blanked" do
    response = { results: [ { id: "1", fields: { "subject" => "Planning", "stray_attribute" => "no" } } ] }

    projected = @index.store.send(:project_hit_fields, response, [ :subject ])

    assert_equal({ subject: "Planning" }, projected[:results].first[:fields])
  end

  test "a filter-only query returns the stored text field" do
    skip "sqlite response parsing; the sqlite run covers this" unless store_adapter_name == :sqlite

    article = Article.create!(title: "FilterOnly", content: "text", account_id: 77)
    ActiveSearch.index(:articles).add(article)

    hit_fields = ActiveSearch.index(:articles)
      .filter(account_id: 77).hit_fields(:title, :account_id).results.first.hit.fields

    assert_equal 77, hit_fields[:account_id]
    assert_equal "FilterOnly", hit_fields[:title]
  end

  private
    def searched_fields
      @index.search("Planning").results.first.hit.fields
    end

    def store_stray_attribute
      skip "#{store_adapter_name} #{WRITER_NARROWS_TO_STORE[store_adapter_name]}" if
        WRITER_NARROWS_TO_STORE.key?(store_adapter_name)

      record = Topic.create!(subject: "Planning", account_id: 1)
      stray = ->(r) { { subject: r.subject, account_id: r.account_id, stray_attribute: "not yours" } }

      overriding(Topic._index_reflections[:topics], :serializer, -> { stray }) do
        without_field_validation { @index.add(record) }
      end

      @index.store.refresh(:topics) rescue nil
    end

    def without_projection(&block)
      overriding(@index.store, :project_hit_fields, ->(response, _names) { response }, &block)
    end

    def without_field_validation
      original = ActiveSearch::Document.instance_method(:validate_fields!)
      ActiveSearch::Document.define_method(:validate_fields!) { }
      yield
    ensure
      ActiveSearch::Document.define_method(:validate_fields!, original)
      ActiveSearch::Document.send(:private, :validate_fields!)
    end

    def overriding(object, name, replacement)
      object.define_singleton_method(name, &replacement)
      yield
    ensure
      object.singleton_class.send(:remove_method, name)
    end
end
