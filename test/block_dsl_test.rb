require "test_helper"

class BlockDslTest < ActiveSupport::TestCase
  def record_with(**attributes)
    Struct.new(*attributes.keys, keyword_init: true).new(**attributes)
  end

  test "text collects text field" do
    builder = ActiveSearch::Index::Schema.new
    builder.text :title

    fields = builder.raw_fields
    assert_equal 1, fields.size
    assert_equal :title, fields[0][:name]
    assert_equal :text, fields[0][:type]
  end

  test "string collects string field" do
    builder = ActiveSearch::Index::Schema.new
    builder.string :status

    fields = builder.raw_fields
    assert_equal 1, fields.size
    assert_equal :status, fields[0][:name]
    assert_equal :string, fields[0][:type]
  end

  test "integer collects integer field" do
    builder = ActiveSearch::Index::Schema.new
    builder.integer :account_id

    fields = builder.raw_fields
    assert_equal 1, fields.size
    assert_equal :account_id, fields[0][:name]
    assert_equal :integer, fields[0][:type]
  end

  test "float collects float field" do
    builder = ActiveSearch::Index::Schema.new
    builder.float :price

    fields = builder.raw_fields
    assert_equal 1, fields.size
    assert_equal :price, fields[0][:name]
    assert_equal :float, fields[0][:type]
  end

  test "boolean collects boolean field" do
    builder = ActiveSearch::Index::Schema.new
    builder.boolean :featured

    fields = builder.raw_fields
    assert_equal 1, fields.size
    assert_equal :featured, fields[0][:name]
    assert_equal :boolean, fields[0][:type]
  end

  test "datetime collects datetime field" do
    builder = ActiveSearch::Index::Schema.new
    builder.datetime :published_at

    fields = builder.raw_fields
    assert_equal 1, fields.size
    assert_equal :published_at, fields[0][:name]
    assert_equal :datetime, fields[0][:type]
  end

  test "date collects date field" do
    builder = ActiveSearch::Index::Schema.new
    builder.date :published_on

    fields = builder.raw_fields
    assert_equal 1, fields.size
    assert_equal :published_on, fields[0][:name]
    assert_equal :date, fields[0][:type]
  end

  test "schema collects multiple fields in order" do
    builder = ActiveSearch::Index::Schema.new
    builder.text :title
    builder.text :body
    builder.string :status
    builder.integer :account_id

    fields = builder.raw_fields
    assert_equal 4, fields.size
    assert_equal %i[title body status account_id], fields.map { |f| f[:name] }
  end

  test "a name declared twice raises, whatever the types" do
    [ [ :text, :string ], [ :text, :text ], [ :text, :integer ] ].each do |first, second|
      error = assert_raises(ActiveSearch::ConfigurationError, "#{first} + #{second} was allowed") do
        ActiveSearch::Index::Schema.from_block(proc {
          send(first, :category)
          send(second, :category)
        }, index_name: :twice)
      end

      assert_match(/declares :category twice/, error.message)
      assert_match(/Use two names/, error.message)
    end
  end

  test "an option nothing reads is refused rather than accepted" do
    error = assert_raises(ActiveSearch::ConfigurationError) do
      ActiveSearch::Index::Field.new(:title, :text, weight: 2, analyzer: "english")
    end

    assert_match(/Unknown options :weight, :analyzer on field :title/, error.message)
    assert_match(/multiple: is the only field option/, error.message)
  end

  test "a field named id or score is lexically valid; only a store can refuse it" do
    [ :id, :score ].each do |name|
      assert_equal name, ActiveSearch::Index::Field.new(name, :integer).name
    end
  end

  test "a field name that is not a bare identifier is refused" do
    [ :Title, :"data->>'x'", :_hidden, :a__b, :"1st" ].each do |name|
      error = assert_raises(ActiveSearch::ConfigurationError, "#{name.inspect} was allowed") do
        ActiveSearch::Index::Field.new(name, :string)
      end

      assert_match(/Invalid field name/, error.message)
    end
  end

  test "extract calls public_send on record" do
    field = ActiveSearch::Index::Field.new(:title, :text)
    record = record_with(title: "Hello")
    assert_equal "Hello", field.extract(record)
  end

  test "extract raises when record does not respond to name" do
    field = ActiveSearch::Index::Field.new(:missing_field, :string)
    record = record_with(title: "Hello")
    error = assert_raises(ActiveSearch::ConfigurationError) { field.extract(record) }
    assert_match(/does not respond to :missing_field/, error.message)
  end

  test "define_index registers index with type-based fields" do
    idx = ActiveSearch.define_index(:ext_test) do
      text :title
      text :body
      string :category
    end

    assert_instance_of ActiveSearch::Index, idx
    assert_equal :ext_test, idx.name
    assert_equal :text, idx.definition[:title].type
    assert_equal :string, idx.definition[:category].type
    assert_same idx, ActiveSearch.index(:ext_test)
  end

  test "define_index with polymorphic: true creates polymorphic index" do
    idx = ActiveSearch.define_index(:poly_ext_test, polymorphic: true) do
      text :title
      integer :account_id
    end

    assert idx.source.is_a?(ActiveSearch::Source::Polymorphic)
  end

  test "polymorphic: true refuses an index name whose singular is not a valid column" do
    [ :s, :audit_s ].each do |name|
      error = assert_raises(ActiveSearch::ConfigurationError, "#{name.inspect} was accepted") do
        ActiveSearch.define_index(name, polymorphic: true) { text :title }
      end
      assert_match(/cannot derive a role/, error.message)
    end
  end

  test "polymorphic: true on an invalid index name reports the name, not a derived role" do
    error = assert_raises(ActiveSearch::ConfigurationError) do
      ActiveSearch.define_index(:"Invalid Name!", polymorphic: true) { text :title }
    end
    assert_match(/Invalid index name/, error.message)
  end

  test "define_index with route_by sets routing on index" do
    idx = ActiveSearch.define_index(:routed_ext_test, route_by: :account_id) do
      text :title
      integer :account_id
    end

    assert_equal :account_id, idx.route_by
  end

  test "define_index with index_name passes through" do
    idx = ActiveSearch.define_index(:logical_name_test, index_name: :store_name) do
      text :title
    end

    assert_equal :logical_name_test, idx.name
    assert_equal :store_name, idx.index_name
  end

  test "define_index without block raises ConfigurationError" do
    error = assert_raises(ActiveSearch::ConfigurationError) do
      ActiveSearch.define_index(:no_block_test)
    end
    assert_match(/requires a block/, error.message)
  end

  test "invalid index name raises ConfigurationError" do
    error = assert_raises(ActiveSearch::ConfigurationError) do
      ActiveSearch.define_index(:"Invalid Name!") do
        text :title
      end
    end
    assert_match(/Invalid index name/, error.message)
  end

  test "consecutive underscores in index name raises ConfigurationError" do
    error = assert_raises(ActiveSearch::ConfigurationError) do
      ActiveSearch.define_index(:a__b) do
        text :title
      end
    end
    assert_match(/Invalid index name/, error.message)
    assert_match(/single underscores/, error.message)
  end

  test "define_index creates convention source from index name" do
    idx = ActiveSearch.define_index(:source_attach_test) do
      text :title
      integer :account_id
    end

    assert idx.source, "Index should have a source from define_index"
    assert_instance_of ActiveSearch::Source::Record, idx.source
    assert_equal :source_attach_test, idx.source.name
  end

  test "define_index source name is singular model-style" do
    idx = ActiveSearch.define_index(:source_name_test) do
      text :title
    end

    assert_equal :source_name_test, idx.source.name
  end

  test "define_index with explicit source: string" do
    idx = ActiveSearch.define_index(:explicit_source_test, source: "Article") do
      text :title
    end

    assert_instance_of ActiveSearch::Source::Record, idx.source
    assert_equal Article, idx.source.model_class
  end

  test "define_index with polymorphic: true and source: raises" do
    error = assert_raises(ActiveSearch::ConfigurationError) do
      ActiveSearch.define_index(:poly_source_test, polymorphic: true, source: "Article") do
        text :title
      end
    end
    assert_match(/polymorphic: or source:, not both/, error.message)
  end

  test "has_search creates reflections" do
    ActiveSearch.define_index(:reflected_test) do
      text :title
      integer :account_id
    end

    klass = build_model_class("ReflectedArticle", "articles") do
      has_search index: :reflected_test
    end

    assert klass._index_reflections.key?(:reflected_test)
    assert klass.respond_to?(:search)
    assert_not klass.respond_to?(:search_index),
      "search_index was removed; a model reaches its index through .search"
  end

  test "has_search infers index name from table_name" do
    klass = build_model_class("InferredArticle", "articles") do
      has_search
    end

    assert klass._index_reflections.key?(:articles)
  end

  test "has_search normalizes string name to symbol" do
    klass = Class.new(ApplicationRecord) do
      self.table_name = "articles"
      include ActiveSearch::Indexable
      has_search index: "articles"
    end

    assert klass._index_reflections.key?(:articles), "String name should be stored as symbol key"
    refute klass._index_reflections.key?("articles"), "String key should not exist"
  end

  test "single has_search is implicitly default" do
    ActiveSearch.define_index(:single_default_test) do
      text :title
    end

    klass = build_model_class("SingleDefaultModel", "articles") do
      has_search index: :single_default_test
    end

    assert_equal :single_default_test, klass.search("anything").index.name
  end

  test "multiple indexes with default: true picks the default" do
    ActiveSearch.define_index(:multi_default_a) do
      text :title
    end
    ActiveSearch.define_index(:multi_default_b) do
      text :title
    end

    klass = build_model_class("MultiDefaultModel", "articles") do
      has_search index: :multi_default_a, default: true
      has_search index: :multi_default_b
    end

    assert_equal :multi_default_a, klass.search("anything").index.name
  end

  test "an explicit default on a later index wins over the first declared" do
    ActiveSearch.define_index(:later_default_a) { text :title }
    ActiveSearch.define_index(:later_default_b) { text :title }

    klass = build_model_class("LaterDefaultModel", "articles") do
      has_search index: :later_default_a
      has_search index: :later_default_b, default: true
    end

    assert_equal :later_default_b, klass.search("anything").index.name
  end

  test "multiple indexes without default use the first declared" do
    ActiveSearch.define_index(:no_default_a) do
      text :title
    end
    ActiveSearch.define_index(:no_default_b) do
      text :title
    end

    klass = build_model_class("NoDefaultModel", "articles") do
      has_search index: :no_default_a
      has_search index: :no_default_b
    end

    assert_equal :no_default_a, klass.search("anything").index.name
  end

  test "two defaults raises at declaration time" do
    ActiveSearch.define_index(:two_default_a) do
      text :title
    end
    ActiveSearch.define_index(:two_default_b) do
      text :title
    end

    error = assert_raises(ActiveSearch::ConfigurationError) do
      build_model_class("TwoDefaultModel", "articles") do
        has_search index: :two_default_a, default: true
        has_search index: :two_default_b, default: true
      end
    end
    assert_match(/already has :two_default_a as its default/, error.message)
  end

  test ".index(:name) returns specific index" do
    ActiveSearch.define_index(:specific_a) do
      text :title
    end
    ActiveSearch.define_index(:specific_b) do
      text :title
    end

    klass = build_model_class("SpecificModel", "articles") do
      has_search index: :specific_a, default: true
      has_search index: :specific_b
    end

    assert_equal :specific_a, klass.search("anything").index.name
    assert_equal :specific_b, ActiveSearch.index(:specific_b).name
  end

  test "serializer builds document hash" do
    ActiveSearch.define_index(:serializer_test) do
      text :title
      integer :account_id
    end

    klass = build_model_class("SerializerModel", "articles") do
      has_search index: :serializer_test, serializer: ->(r) { { title: r.title.upcase, account_id: r.account_id } }
    end

    reflection = klass._index_reflections[:serializer_test]
    idx = ActiveSearch.index(:serializer_test)
    record = record_with(title: "hello", account_id: 1)

    data = reflection.serialize(record, idx.definition)
    assert_equal "HELLO", data[:title]
    assert_equal 1, data[:account_id]
  end

  test "auto_serialize uses field extraction via public_send" do
    reflection = Article._index_reflections[:articles]
    idx = ActiveSearch.index(:articles)
    record = record_with(title: "test", content: "body", account_id: 7, status: "draft",
      published_at: nil, published_on: nil, featured: false)

    data = reflection.serialize(record, idx.definition)
    assert_equal "test", data[:title]
    assert_equal 7, data[:account_id]
  end

  test "reflection sees redefined index after re-registration" do
    ActiveSearch.define_index(:stale_ref_test) do
      text :title
    end

    klass = build_model_class("StaleReflectionArticle", "articles") do
      has_search index: :stale_ref_test
    end

    reflection = klass._index_reflections[:stale_ref_test]
    v1 = reflection.index
    assert_equal [ :title ], v1.definition.field_names

    ActiveSearch.define_index(:stale_ref_test) do
      text :title
      text :body
      string :status
    end

    v2 = reflection.index
    assert_equal [ :title, :body, :status ], v2.definition.field_names,
      "Reflection should see the redefined index, not the stale cached one"
  end

  private
    def build_model_class(name, table_name, &block)
      klass = Class.new(ApplicationRecord) do
        self.table_name = table_name
        include ActiveSearch::Indexable
      end

      stub_const(name, klass)
      klass.class_eval(&block)
      klass
    end

    def stub_const(name, klass)
      Object.const_set(name, klass) unless Object.const_defined?(name)
      klass.define_singleton_method(:name) { name }
    end
end
