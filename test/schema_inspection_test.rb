require "test_helper"

class SchemaInspectionTest < ActiveSupport::TestCase
  searches :articles

  setup do
    @index = ActiveSearch.index(:articles)
  end

  test "reports the fields the index really holds" do
    inspection = @index.store.inspect_schema(@index)

    assert inspection.found?
    assert_not inspection.unavailable?

    required = @index.store.schema_requirements(@index)
    title = inspection.satisfying(required.find { |r| r.name == "title" })

    assert title, "no observation met title, got #{inspection.observed.map { |o| [ o.name, o.role, o.location ].compact.join("/") }}"
    assert_includes [ :searchable, nil ], title.role
  end

  test "a state outside STATES is rejected at construction rather than read as missing later" do
    error = assert_raises(ArgumentError) do
      ActiveSearch::Schema::Inspection.new(state: :unavailble)
    end

    assert_match(/:unavailble/, error.message)
    assert_match(/found, missing, unavailable/, error.message)
  end

  test "a declared field the index does not hold is reported as absent, not as an error" do
    inspection = @index.store.inspect_schema(@index)

    assert_empty inspection.observations_for("no_such_field")
  end

  test "a database adapter says which table each field is in" do
    skip "#{store_adapter_name} keeps one table" unless store_adapter_name == :sqlite

    required = @index.store.schema_requirements(@index)
    title = required.find { |r| r.name == "title" }
    status = required.find { |r| r.name == "status" }

    assert_equal "article_documents_fts", title.location
    assert_equal "article_documents", status.location

    inspection = @index.store.inspect_schema(@index)
    assert_equal "article_documents_fts", inspection.satisfying(title).location
    assert_equal "article_documents", inspection.satisfying(status).location
  end

  test "requirements name every declared field and say what it is for" do
    required = @index.store.schema_requirements(@index)

    assert_equal @index.definition.field_names.map(&:to_s).sort,
      (required.map(&:name).uniq - key_columns).sort
    assert required.all?(&:role), "every requirement must say what the field is for"
    assert_includes roles_for(required, "title"), :searchable
    assert_includes roles_for(required, "status"), :filterable
  end

  test "the FTS table alone counts as present" do
    skip "#{store_adapter_name} has no FTS side table" unless store_adapter_name == :sqlite

    connection = ActiveRecord::Base.connection

    begin
      connection.execute("CREATE VIRTUAL TABLE probe_documents_fts USING fts5(title)")
      assert_not connection.table_exists?("probe_documents"),
        "premise: only the FTS half may exist for this to mean anything"

      assert @index.store.send(:index_present?, "probe_documents", connection)

      connection.execute("DROP TABLE probe_documents_fts")
      assert_not @index.store.send(:index_present?, "probe_documents", connection)
    ensure
      connection.execute("DROP TABLE IF EXISTS probe_documents_fts")
    end
  end

  test "schema reading goes through the adapter's own model" do
    skip "#{store_adapter_name} keeps no table" unless %i[ sqlite mysql postgresql ].include?(store_adapter_name)
    store = @index.store
    elsewhere = Class.new(ActiveRecord::Base) { self.table_name = "articles" }

    assert_equal "article_documents", store.send(:document_table_name, @index),
      "premise: it must resolve the usual table before the override"

    overriding(store, :model_for, ->(_index) { elsewhere }) do
      assert_equal "articles", store.send(:document_table_name, @index)
      assert_equal "articles", store.send(:schema_locations, @index)[:filterable]
    end
  end

  test "requirements name the key columns a database reads and writes by" do
    skip "#{store_adapter_name} does not join a document to a row" unless
      %i[ sqlite mysql postgresql ].include?(store_adapter_name)
    required = @index.store.schema_requirements(@index)

    assert_not_empty key_columns
    key_columns.each do |column|
      assert_includes roles_for(required, column), :filterable, "#{column} is not required"
    end
  end

  private
    def overriding(object, name, replacement)
      object.define_singleton_method(name, &replacement)
      yield
    ensure
      object.singleton_class.send(:remove_method, name)
    end

    def key_columns
    @index.source.storage_key_columns.map(&:to_s)
  end

  def roles_for(required, name)
      required.select { |r| r.name == name }.map(&:role)
    end
end
