require "test_helper"

class SchemaVerificationTest < ActiveSupport::TestCase
  searches :articles

  setup do
    @index = ActiveSearch.index(:articles)
  end

  test "a live index that provides the declaration is compatible" do
    verification = ActiveSearch::Schema.verify(@index)

    assert verification.compatible?, verification.describe
    assert_equal 0, verification.exit_code
  end

  test "a field the index does not hold is reported, and named" do
    inspection = @index.store.inspect_schema(@index)
    required = @index.store.schema_requirements(@index) + [ missing_requirement ]

    verification = ActiveSearch::Schema::Verification.of(:articles, required, inspection)

    assert_not verification.compatible?
    assert_equal :incompatible, verification.outcome
    assert_equal 1, verification.exit_code
    assert_equal [ "never_declared" ], verification.unmet.map(&:name)
    assert_match "never_declared", verification.describe
  end

  test "a store that cannot report a schema says unsupported, not compatible" do
    verification = ActiveSearch::Schema.verify(index_on(ActiveSearch::StoreAdapters::Base.new))

    assert_equal :unsupported, verification.outcome
    assert_not verification.compatible?
    assert_equal 4, verification.exit_code
  end

  test "an index whose store cannot resolve is reported, not raised" do
    index = ActiveSearch::Index.new(:articles_typo, definition: @index.definition, store_name: :nonexistent)

    verification = ActiveSearch::Schema.verify(index)

    assert_equal :error, verification.outcome
    assert_equal :articles_typo, verification.index_name
  end

  test "a store that cannot be reached is not an index that needs creating" do
    inspection = ActiveSearch::Schema::Inspection.new(state: :unavailable, detail: "connection refused")

    verification = ActiveSearch::Schema::Verification.of(:articles, [ missing_requirement ], inspection)

    assert_equal :unavailable, verification.outcome
    assert_not_equal :missing, verification.outcome
    assert_equal 3, verification.exit_code
  end

  test "a missing index reports every requirement as unmet" do
    inspection = ActiveSearch::Schema::Inspection.new(state: :missing)
    required = [ missing_requirement ]

    verification = ActiveSearch::Schema::Verification.of(:articles, required, inspection)

    assert_equal :missing, verification.outcome
    assert_equal required, verification.unmet
    assert_equal 2, verification.exit_code
  end

  test "a field of the wrong native type is refused, not accepted as filterable" do
    index = ActiveSearch.index(:articles)
    required = index.store.schema_requirements(index).find { |r| r.field == :account_id }
    skip "#{store_adapter_name} does not type a field" unless required.native_type

    accepted = Array(required.native_type)
    observing = ->(native_type) do
      ActiveSearch::Schema::Inspection.new(state: :found, observed: [
        ActiveSearch::Schema::Observation.new(name: "account_id", role: required.role,
          native_type: native_type, location: required.location)
      ])
    end

    wrong = observing.("definitely_not_#{accepted.first}")

    assert_nil wrong.satisfying(required)

    right = observing.(accepted.first)

    assert right.satisfying(required), "the control must pass, or the refusal above proves nothing"
  end

  test "an index that has never been built reports missing rather than raising" do
    skip "only a database adapter resolves a document model" unless
      %i[ sqlite mysql postgresql ].include?(store_adapter_name)

    verification = nil
    assert_nothing_raised { verification = ActiveSearch::Schema.verify(ActiveSearch.index(:products)) }

    assert_equal :missing, verification.outcome
    assert_not verification.compatible?
  end

  test "an adapter that fails is reported as failing, not as a limit of the engine" do
    failing = Class.new(@index.store.class) do
      def schema_requirements(_index)
        raise ActiveSearch::QueryError, "No shard is in scope"
      end
    end.allocate

    verification = ActiveSearch::Schema.verify(index_on(failing))

    assert_equal :error, verification.outcome
    assert_match "No shard is in scope", verification.describe
    assert_match "QueryError", verification.describe, "the message must say what actually happened"
    assert_equal 5, verification.exit_code
  end

  test "a store that cannot describe an index is unsupported, not failing" do
    silent = Class.new(@index.store.class) do
      def inspect_schema(_index)
        raise NotImplementedError, "Silent cannot report an index's schema"
      end
    end.allocate

    verification = ActiveSearch::Schema.verify(index_on(silent))

    assert_equal :unsupported, verification.outcome
    assert_equal 4, verification.exit_code
  end

  test "a mapping that cannot do what the declaration promises is refused" do
    skip "#{store_adapter_name} has no mapping" unless %i[ elasticsearch opensearch ].include?(store_adapter_name)
    store = @index.store

    { [ :integer, "long" ] => true, [ :integer, "keyword" ] => false, [ :integer, "integer" ] => false,
      [ :string, "keyword" ] => true, [ :string, "text" ] => false,
      [ :text, "text" ] => true, [ :text, "keyword" ] => false,
      [ :float, "double" ] => true, [ :float, "float" ] => false,
      [ :datetime, "date" ] => true, [ :datetime, "long" ] => false }.each do |(declared, mapped), expected|
      required = ActiveSearch::Schema::Requirement.new(field: :f, role: :filterable, name: "f",
        native_type: store.expected_native_type(ActiveSearch::Index::Field.new(:f, declared)))
      seen = ActiveSearch::Schema::Inspection.new(state: :found, observed: [
        ActiveSearch::Schema::Observation.new(name: "f", role: :filterable, native_type: mapped)
      ])

      assert_equal expected, !seen.satisfying(required).nil?, "declared #{declared} against #{mapped}"
    end
  end

  test "an Elasticsearch field that cannot sort or find a nil is not filterable" do
    skip "#{store_adapter_name} has no mapping" unless %i[ elasticsearch opensearch ].include?(store_adapter_name)
    store = @index.store

    assert_equal :filterable, store.send(:observe_field, "f", { "type" => "keyword" }).role
    assert_nil store.send(:observe_field, "f", { "type" => "keyword", "doc_values" => false }).role
    assert_nil store.send(:observe_field, "f", { "type" => "keyword", "null_value" => "NONE" }).role
    assert_equal :searchable, store.send(:observe_field, "f", { "type" => "text" }).role
  end

  test "an unqueryable Elasticsearch field satisfies nothing" do
    skip "#{store_adapter_name} has no index mapping option" unless %i[ elasticsearch opensearch ].include?(store_adapter_name)
    store = @index.store

    assert_equal :searchable, store.send(:observe_field, "title", { "type" => "text" }).role
    assert_nil store.send(:observe_field, "title", { "type" => "text", "index" => false }).role

    required = ActiveSearch::Schema::Requirement.new(field: :title, role: :searchable,
      name: "title", native_type: "text")
    disabled = ActiveSearch::Schema::Inspection.new(state: :found,
      observed: [ store.send(:observe_field, "title", { "type" => "text", "index" => false }) ])

    assert_nil disabled.satisfying(required)
  end

  test "a Solr class that cannot do what the declaration promises is refused" do
    skip "#{store_adapter_name} has no field classes" unless store_adapter_name == :solr
    store = @index.store

    { [ :integer, "solr.LongPointField" ] => true, [ :integer, "solr.StrField" ] => false,
      [ :integer, "solr.IntPointField" ] => false, [ :string, "solr.StrField" ] => true,
      [ :date, "solr.DatePointField" ] => true, [ :date, "solr.BoolField" ] => false }.each do |(declared, observed), expected|
      required = ActiveSearch::Schema::Requirement.new(field: :f, role: :filterable, name: "f",
        native_type: store.expected_native_type(ActiveSearch::Index::Field.new(:f, declared)))
      seen = ActiveSearch::Schema::Inspection.new(state: :found, observed: [
        ActiveSearch::Schema::Observation.new(name: "f", role: :filterable, native_type: observed)
      ])

      assert_equal expected, !seen.satisfying(required).nil?, "declared #{declared} against #{observed}"
    end
  end

  test "a Solr field that cannot sort is not filterable" do
    skip "#{store_adapter_name} has no docValues" unless store_adapter_name == :solr
    store = @index.store
    string = "solr.StrField"

    assert_equal :filterable, store.send(:role_for, { "indexed" => false }, string)
    assert_nil store.send(:role_for, { "docValues" => false }, string)
    assert_nil store.send(:role_for, { "indexed" => false, "docValues" => false }, string)
    assert_nil store.send(:role_for, { "indexed" => false }, "solr.TextField")
    assert_equal :searchable, store.send(:role_for, {}, "solr.TextField")
  end

  test "an observation that names no type does not satisfy a requirement that does" do
    required = ActiveSearch::Schema::Requirement.new(field: :account_id, role: :filterable,
      name: "account_id", native_type: "integer")
    silent = ActiveSearch::Schema::Inspection.new(state: :found, observed: [
      ActiveSearch::Schema::Observation.new(name: "account_id", role: :filterable)
    ])

    assert_nil silent.satisfying(required)

    unchecked = ActiveSearch::Schema::Requirement.new(field: :account_id, role: :filterable,
      name: "account_id")

    assert silent.satisfying(unchecked), "a requirement naming no type must accept any observation"
  end

  test "a wildcard searchable list is not read as a missing field" do
    skip "#{store_adapter_name} has no wildcard attribute list" unless store_adapter_name == :meilisearch

    with_meilisearch_setting(:searchable_attributes) do |idx|
      store.send(:await, idx.update_searchable_attributes([ "*" ]))

      assert_equal :compatible, ActiveSearch::Schema.verify(@index).outcome
    end
  end

  test "a collection is not required to be sortable" do
    skip "#{store_adapter_name} has no sortable attribute list" unless store_adapter_name == :meilisearch
    probe = ActiveSearch.index(:collection_probes)
    collections = probe.definition.fields.select(&:multiple?).map { |f| f.name.to_s }
    scalars = probe.definition.fields.reject { |f| f.multiple? || f.searchable? }.map { |f| f.name.to_s }
    assert collections.any?, "premise: the probe must declare a collection"

    sortable = probe.store.schema_requirements(probe).select { |r| r.role == :sortable }.map(&:name)

    assert_empty sortable & collections
    assert_equal scalars.sort, (sortable & scalars).sort
  end

  test "a filterable attribute that is not sortable is refused" do
    skip "#{store_adapter_name} has no sortable attribute list" unless store_adapter_name == :meilisearch

    with_meilisearch_setting(:sortable_attributes) do |idx|
      assert_equal :compatible, ActiveSearch::Schema.verify(@index).outcome,
        "premise: the index must verify before the sortable list is emptied"

      store.send(:await, idx.update_sortable_attributes([]))
      verification = ActiveSearch::Schema.verify(@index)

      assert_equal :incompatible, verification.outcome, verification.describe
      assert_equal [ :sortable ], verification.unmet.map(&:role).uniq
    end
  end

  private
    def field_of(type)
      ActiveSearch::Index::Field.new(:f, type)
    end
    def with_solr_fields(fields)
      require "net/http"
      require "json"
      client = @index.store.send(:client, @index.index_name)
      schema = URI("#{client.uri.to_s.sub(%r{/[^/]*$}, "")}/schema")
      post = ->(body) do
        request = Net::HTTP::Post.new(schema.path, "Content-Type" => "application/json")
        request.body = body.to_json
        Net::HTTP.new(schema.host, schema.port).request(request)
      end

      fields.each { |name, spec| post.({ "add-field" => { "name" => name, "type" => "string", "stored" => true }.merge(spec) }) }
      yield
    ensure
      fields.each_key { |name| post.({ "delete-field" => { "name" => name } }) }
    end
    def with_meilisearch_setting(name)
      idx = store.client.index("articles")
      original = Array(idx.settings[name.to_s.camelize(:lower)])
      yield idx
    ensure
      store.send(:await, idx.public_send("update_#{name}", original)) if original
    end
    def index_on(store)
      index = @index
      Struct.new(:name, :index_name, :definition, :source, :store, :document_class) do
        def document_class_name = document_class || "#{name.to_s.classify}Document"
        def index_name_for(_store) = index_name
      end.new(
        index.name, index.index_name, index.definition, index.source, store, nil)
    end

    def missing_requirement
      ActiveSearch::Schema::Requirement.new(field: :never_declared, role: :searchable,
        name: "never_declared", location: nil, native_type: nil)
    end
end
