require "test_helper"
require "generators/active_search/document/document_generator"

class SchemaCreationTest < ActiveSupport::TestCase
  searches :articles

  setup do
    @store = ActiveSearch.index(:articles).store
    @probe = ActiveSearch.index(:creation_probes)
    drop_probe if creatable?
  end

  teardown { drop_probe if creatable? }

  test "creates an index that then verifies against its own declaration" do
    skip "#{store_adapter_name} does not create an index directly" unless creatable?
    assert_equal :missing, ActiveSearch::Schema.verify(@probe).outcome

    @probe.store.create_index(@probe)

    verification = ActiveSearch::Schema.verify(@probe)
    assert verification.compatible?, verification.describe
  end

  test "a collection it creates verifies too" do
    skip "#{store_adapter_name} does not create an index directly" unless creatable?
    probe = ActiveSearch.index(:collection_probes)
    assert probe.definition.fields.any?(&:multiple?), "premise: the probe must declare a collection"
    probe.store.drop_index(probe) rescue nil

    probe.store.create_index(probe)

    verification = ActiveSearch::Schema.verify(probe)
    assert verification.compatible?, verification.describe
  ensure
    probe&.store&.drop_index(probe) rescue nil
  end

  test "a filterable field built without INDEXMISSING is refused" do
    skip "#{store_adapter_name} has no INDEXMISSING flag" unless store_adapter_name == :redis_search
    plan = @probe.store.creation_plan(@probe)
    stripped = plan.native.reject { |token| token == "INDEXMISSING" }
    flagged = @probe.definition.fields.reject(&:searchable?).size
    assert_operator flagged, :>, 0, "premise: the probe must declare a filterable field"
    assert_equal plan.native.size - flagged, stripped.size, "premise: one flag per filterable field"

    @probe.store.send(:client).call("FT.CREATE", *stripped)
    verification = ActiveSearch::Schema.verify(@probe)

    assert_equal :incompatible, verification.outcome, verification.describe
    assert_includes verification.unmet.map(&:name), "status"
  end

  test "an index that already provides the declaration is nothing to do" do
    skip "#{store_adapter_name} does not create an index directly" unless creatable?
    @probe.store.create_index(@probe)
    plan = @probe.store.create_index(@probe)

    assert_equal({ @probe.index_name.to_s => "already built" }, plan.describes)
    assert plan.applied
  end

  test "an index that exists without a declared field is refused, and the field is named" do
    skip "#{store_adapter_name} does not create an index directly" unless creatable?
    @probe.store.create_index(@probe)
    mismatched = ActiveSearch.define_index(:mismatch_probe, source: "Article",
      index_name: @probe.index_name) { text :title; string :never_built }

    error = assert_raises(ActiveSearch::Schema::CreationRefused) { mismatched.store.create_index(mismatched) }

    assert_match "never_built", error.message
  ensure
    ActiveSearch.configuration.unregister_index(:mismatch_probe)
  end

  test "an index built without a declared field is caught, and the field is named" do
    skip "#{store_adapter_name} does not create an index directly" unless creatable?
    narrowed = @probe.store.creation_plan(@probe)
    @probe.store.send(:apply_creation_plan, without_status(narrowed))

    verification = ActiveSearch::Schema.verify(@probe)

    assert_equal :incompatible, verification.outcome
    assert_equal [ "status" ], verification.unmet.map(&:name).uniq
    assert_match "status", verification.describe
  end

  test "the same index built with every declared field is compatible" do
    skip "#{store_adapter_name} does not create an index directly" unless creatable?
    @probe.store.send(:apply_creation_plan, @probe.store.creation_plan(@probe))

    assert ActiveSearch::Schema.verify(@probe).compatible?
  end

  test "a plan can be read without a store, and says what it would build" do
    skip "#{store_adapter_name} does not create an index directly" unless creatable?
    plan = @probe.store.creation_plan(@probe)

    assert_equal :creation_probes, plan.index_name
    assert_includes plan.describes.keys.map(&:to_s), "title"
    assert_includes plan.describes.keys.map(&:to_s), "status"
  end

  test "an adapter that composes no plan raises rather than returning one" do
    skip "#{store_adapter_name} composes a plan" if creatable?

    error = assert_raises(NotImplementedError) { @probe.store.creation_plan(@probe) }
    assert_no_match(/cannot create an index/, error.message) if database_adapter?
  end

  test "the generator loads in a process that has not already loaded the generator framework" do
    root = File.expand_path("..", __dir__)
    script = 'require "rails"; require "active_search"; ' \
             'require "./lib/generators/active_search/document/document_generator"; print "ok"'

    output = Dir.chdir(root) { %x(#{Gem.ruby} -Ilib -e #{script.shellescape} 2>&1) }

    assert_equal "ok", output, "loading the generator standalone failed:\n#{output}"
  end

  test "creating an index writes nothing into the application" do
    skip "only a database adapter generates a document class" unless database_adapter?
    index = ActiveSearch.index(:creation_probes)
    path = document_model_path(:creation_probes)
    original = path.read
    migrations = Dir.glob(Rails.root.join("db/migrate/*.rb")).size

    begin
      path.write("#{original.sub(/\nend\n?\z/, "")}\n  scope :recent, -> { all }\nend\n")
      error = assert_raises(ActiveSearch::Schema::CreationRefused) { index.store.create_index(index) }
      survived = path.read
    ensure
      path.write(original)
    end

    assert_match "rails generate active_search:document creation_probes", error.message
    assert_match "db:migrate", error.message
    assert_includes survived, "scope :recent"
    assert_equal migrations, Dir.glob(Rails.root.join("db/migrate/*.rb")).size
  end

  test "a refused structure leaves no document class behind" do
    skip "only a database adapter generates a document class" unless database_adapter?
    path = document_model_path(:articles)
    original = path.read

    begin
      path.delete
      assert_raises(Rails::Generators::Error) { generate_document_for(ActiveSearch.index(:articles)) }
      written = path.exist?
    ensure
      path.write(original)
    end

    assert_not written, "the class was written for a table the same run refused to build"
  end

  private
    def document_model_path(index_name)
      ActiveSearch::StoreAdapters::Database::DocumentClass.path_for(ActiveSearch.index(index_name))
    end

    def creatable?
      capabilities.supports_index_creation? && !database_adapter?
    end

    def database_adapter?
      %i[ sqlite mysql postgresql ].include?(store_adapter_name)
    end

    def without_status(_plan)
      fields = @probe.definition.fields.reject { |field| field.name == :status }
      narrowed = Struct.new(:name, :index_name, :definition, :document_class) do
        def document_class_name = document_class || "#{name.to_s.classify}Document"
      end.new(
        @probe.name, @probe.index_name, ActiveSearch::Index::Definition.new(fields: fields), nil)

      @probe.store.creation_plan(narrowed)
    end

    def drop_probe
      @probe.store.drop_index(@probe)
    rescue StandardError
      nil
    end
end
