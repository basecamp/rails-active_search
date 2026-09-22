require "test_helper"

class DatabaseDocumentClassTest < ActiveSupport::TestCase
  test "the application's class is used exactly as it is" do
    assert_same ArticleDocument, ActiveSearch::StoreAdapters::Database::DocumentClass.for(index_for(:articles))
  end

  test "one that renames its table keeps working" do
    resolved = ActiveSearch::StoreAdapters::Database::DocumentClass.for(index_for(:namespaced_tests))

    assert_same NamespacedTestDocument, resolved
    assert_equal "search_namespaced_test_documents", resolved.table_name
  end

  test "an application can name the class outright, and the convention is the fallback" do
    named = stub_index(:records, document_class: "Search::RecordDocument")

    assert_equal "Search::RecordDocument",
      ActiveSearch::StoreAdapters::Database::DocumentClass.constant_name_for(named)
    assert_equal "RecordDocument",
      ActiveSearch::StoreAdapters::Database::DocumentClass.constant_name_for(stub_index(:records))
  end

  test "a missing class is refused, and the message says what writes it" do
    error = assert_raises(ActiveSearch::ConfigurationError) do
      ActiveSearch::StoreAdapters::Database::DocumentClass.for(stub_index(:never_declared))
    end

    assert_match "NeverDeclaredDocument", error.message
    assert_match "rails generate active_search:document", error.message
  end

  test "an absent class and an invalid one are different errors" do
    assert_raises(ActiveSearch::StoreAdapters::Database::DocumentClass::Absent) do
      ActiveSearch::StoreAdapters::Database::DocumentClass.for(stub_index(:never_declared))
    end

    Object.const_set(:NotAModelDocument, Module.new)
    error = assert_raises(ActiveSearch::ConfigurationError) do
      ActiveSearch::StoreAdapters::Database::DocumentClass.for(stub_index(:not_a_models))
    end

    assert_not_kind_of ActiveSearch::StoreAdapters::Database::DocumentClass::Absent, error
  ensure
    Object.send(:remove_const, :NotAModelDocument) if Object.const_defined?(:NotAModelDocument)
  end

  test "a constant that is not a concrete model is refused" do
    Object.const_set(:NotAModelDocument, Module.new)

    error = assert_raises(ActiveSearch::ConfigurationError) do
      ActiveSearch::StoreAdapters::Database::DocumentClass.for(stub_index(:not_a_models))
    end

    assert_match "must be a concrete ActiveRecord model", error.message
  ensure
    Object.send(:remove_const, :NotAModelDocument) if Object.const_defined?(:NotAModelDocument)
  end

  test "a declared type field needs the inheritance column turned off" do
    skip "needs a database adapter" unless store_adapter_name == :sqlite
    connection = ActiveRecord::Base.connection
    connection.execute("DROP TABLE IF EXISTS sti_probe_documents")
    connection.execute("CREATE TABLE sti_probe_documents (id INTEGER PRIMARY KEY, type TEXT, title TEXT)")
    connection.execute("INSERT INTO sti_probe_documents (type, title) VALUES ('NotAnyClass', 'hi')")

    resolved = ActiveSearch::StoreAdapters::Database::DocumentClass.for(index_for(:sti_probes))
    assert_same StiProbeDocument, resolved
    assert_equal "hi", resolved.first.title

    control = Class.new(ApplicationRecord) { self.table_name = "sti_probe_documents" }
    assert_raises(ActiveRecord::SubclassNotFound, "without inheritance_column = nil this must fail") do
      control.first
    end
  ensure
    connection&.execute("DROP TABLE IF EXISTS sti_probe_documents")
  end

  test "each identity field is refused with its own reason" do
    type_error = assert_raises(ActiveSearch::ConfigurationError) do
      ActiveSearch.define_index(:reason_type_probe, polymorphic: true) do
        text :title
        integer :reason_type_probe_type
      end
    end
    id_error = assert_raises(ActiveSearch::ConfigurationError) do
      ActiveSearch.define_index(:reason_id_probe, polymorphic: true) do
        text :title
        integer :reason_id_probe_id
      end
    end

    assert_match "records which class a document came from", type_error.message
    assert_match "holds the record's id as text", id_error.message
    assert_no_match(/which class/, id_error.message)
  end

  test "path_for refuses a destination outside app/models" do
    [ "../../config/initializers/owned", "::Foo::Bar" ].each do |escaping|
      stand_in = Struct.new(:name, :document_class_name).new(:records, escaping)

      error = assert_raises(ActiveSearch::ConfigurationError, escaping) do
        ActiveSearch::StoreAdapters::Database::DocumentClass.path_for(stand_in)
      end

      assert_match "outside app/models", error.message
    end
  end

  test "a sibling directory sharing the prefix is outside app/models" do
    root = Rails.root.join("app/models")
    sibling = Rails.root.join("app/models_backup")
    FileUtils.mkdir_p(sibling)

    assert ActiveSearch::StoreAdapters::Database::DocumentClass.send(:within?, root, root.join("x.rb"))
    assert_not ActiveSearch::StoreAdapters::Database::DocumentClass.send(:within?, root, sibling.join("x.rb"))
  ensure
    FileUtils.rmdir(sibling) if sibling&.exist?
  end

  test "a named polymorphic role does not become the index identity" do
    ActiveSearch.define_index(:role_fields_probe, polymorphic: :searchable) { text :title }
    index = ActiveSearch.index(:role_fields_probe)

    assert_equal %i[ searchable_type searchable_id ], index.source.identity_fields
    assert_equal :role_fields_probe, index.source.index_name
    assert_includes index.definition.field_names, :searchable_type
  end

  test "a namespaced document class gets the table Rails will give it" do
    Object.const_set(:NsProbeSpace, Module.new) unless Object.const_defined?(:NsProbeSpace)
    ActiveSearch.define_index(:ns_table_probe, source: "Article",
      document_class: "NsProbeSpace::NsTableProbeDocument") { text :title }
    index = ActiveSearch.index(:ns_table_probe)

    derived = ActiveSearch::StoreAdapters::Database::DocumentClass.table_name_for(index)
    ::NsProbeSpace.const_set(:NsTableProbeDocument, Class.new(ApplicationRecord))

    assert_equal ::NsProbeSpace::NsTableProbeDocument.table_name, derived
  ensure
    ::NsProbeSpace.send(:remove_const, :NsTableProbeDocument) if
      ::NsProbeSpace.const_defined?(:NsTableProbeDocument, false)
  end

  test "a String index name is a Symbol before the source is built" do
    ActiveSearch.define_index("string_name_probe", polymorphic: :searchable) { text :title }
    index = ActiveSearch.index(:string_name_probe)

    assert_equal :string_name_probe, index.name
    assert_equal :string_name_probe, index.source.index_name
  end

  test "a document_class that is not a constant path is refused" do
    [ "foo/bar", "../../owned", "lowercase" ].each do |bad|
      assert_raises(ActiveSearch::ConfigurationError, bad) do
        ActiveSearch::Index.new(:probe, definition: ActiveSearch.index(:articles).definition, document_class: bad)
      end
    end
  end

  test "a module's table_name_prefix reaches the derived table" do
    ActiveSearch.define_index(:prefixed_probe, source: "Article",
      document_class: "PrefixedProbeSpace::EntryDocument") { text :title }

    assert_equal "prefixed_", PrefixedProbeSpace.table_name_prefix
    assert_equal "prefixed_entry_documents",
      ActiveSearch::StoreAdapters::Database::DocumentClass.table_name_for(ActiveSearch.index(:prefixed_probe))
  end

  test "a prefix on ApplicationRecord reaches the derived table" do
    ActiveSearch.define_index(:global_prefix_probe, source: "Article") { text :title }
    previous = ApplicationRecord.table_name_prefix
    ApplicationRecord.table_name_prefix = "global_"

    assert_equal "global_global_prefix_probe_documents",
      ActiveSearch::StoreAdapters::Database::DocumentClass.table_name_for(ActiveSearch.index(:global_prefix_probe))
  ensure
    ApplicationRecord.table_name_prefix = previous
  end

  test "a destination under an app/models that does not exist yet is inside it" do
    absent = Rails.root.join("no_such_models_dir")
    within = ActiveSearch::StoreAdapters::Database::DocumentClass.method(:within?)

    assert within.call(absent, absent.join("x.rb"))
    assert_not within.call(absent, Rails.root.join("elsewhere/x.rb"))
    assert_not within.call(absent, Rails.root.join("no_such_models_dir_backup/x.rb"))
  end

  test "two indexes over one index_name share a document class" do
    ActiveSearch.define_index(:seam_primary, source: "Article", index_name: :seam,
      store_name: :primary) { text :title }
    ActiveSearch.define_index(:seam_secondary, source: "Article", index_name: :seam,
      store_name: :secondary) { text :title }

    assert_equal "SeamDocument", ActiveSearch.index(:seam_primary).document_class_name
    assert_equal "SeamDocument", ActiveSearch.index(:seam_secondary).document_class_name
  end

  test "a hyphenated index_name resolves through the namespace" do
    ActiveSearch.define_index(:hyphen_probe, source: "Article", index_name: :"search-hyphen_probe") { text :title }

    assert_equal "Search::HyphenProbeDocument", ActiveSearch.index(:hyphen_probe).document_class_name
  end

  private
    def index_for(name)
      ActiveSearch.index(name)
    end

    def stub_index(name, **options)
      ActiveSearch::Index.new(name, definition: ActiveSearch.index(:articles).definition, **options)
    end
end
