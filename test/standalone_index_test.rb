require "test_helper"

class StandaloneIndexTest < ActiveSupport::TestCase
  setup do
    @index = ActiveSearch::Index.new(:article, definition: definition)
    ActiveSearch.configuration.register_index(:article, @index)
  end

  teardown do
    ActiveSearch.configuration.unregister_index(:article)
  end

  test "record-level add raises without source" do
    record = Object.new

    error = assert_raises(ActiveSearch::ConfigurationError) do
      @index.add(record)
    end
    assert_match(/has no record source/, error.message)
  end

  test "document_for raises for non-indexable record" do
    index = ActiveSearch.index(:articles)
    record = Object.new

    error = assert_raises(ActiveSearch::ConfigurationError) do
      index.document_for(record)
    end
    assert_match(/must declare `has_search`/, error.message)
  end

  test "index without source has no identity fields" do
    assert_nil @index.source
  end

  test "index_name defaults to name" do
    assert_equal :article, @index.index_name
  end

  test "index_name returns explicit value" do
    idx = ActiveSearch::Index.new(:fulltext, definition: definition, index_name: :recording)
    assert_equal :recording, idx.index_name
    assert_equal :fulltext, idx.name
  end

  test "invalid index_name raises ConfigurationError" do
    error = assert_raises(ActiveSearch::ConfigurationError) do
      ActiveSearch::Index.new(:valid, definition: definition, index_name: :"Invalid Name!")
    end
    assert_match(/Invalid index_name/, error.message)
  end

  test "index_name wears the store's index_prefix" do
    with_store_prefix("dev_") { assert_equal :dev_article, @index.index_name }
  end

  test "the document class name ignores the prefix, since it names Ruby not a store index" do
    with_store_prefix("dev_") { assert_equal "ArticleDocument", @index.document_class_name }
  end

  test "a database store contributes no prefix, and a document store honours the option" do
    assert_nil ActiveSearch::StoreAdapters::Sqlite.new.index_prefix
    assert_equal "dev_", ActiveSearch::StoreAdapters::Base.new(index_prefix: "dev_").index_prefix
  end

  test "index_prefix is kept out of the options an adapter forwards to its client" do
    store = ActiveSearch::StoreAdapters::Base.new(index_prefix: "dev_", host: "localhost")
    assert_not_includes store.options.keys, :index_prefix
    assert_equal "localhost", store.options[:host]
  end

  test "a malformed index_prefix is refused when the store is built" do
    error = assert_raises(ActiveSearch::ConfigurationError) do
      ActiveSearch::StoreAdapters::Base.new(index_prefix: "Bad Prefix/")
    end
    assert_match(/Invalid index_prefix/, error.message)
  end

  test "a blank-but-present index_prefix is refused, not treated as no prefix" do
    assert_nil ActiveSearch::StoreAdapters::Base.new(index_prefix: "").index_prefix
    assert_raises(ActiveSearch::ConfigurationError) { ActiveSearch::StoreAdapters::Base.new(index_prefix: " ") }
  end

  test "a non-String index_prefix is refused" do
    assert_raises(ActiveSearch::ConfigurationError) { ActiveSearch::StoreAdapters::Base.new(index_prefix: :dev) }
    assert_raises(ActiveSearch::ConfigurationError) { ActiveSearch::StoreAdapters::Base.new(index_prefix: SimpleDelegator.new("")) }
  end

  private
    def with_store_prefix(prefix)
      @index.define_singleton_method(:store) { Struct.new(:index_prefix).new(prefix) }
      yield
    end

    def definition
      fields = [
        ActiveSearch::Index::Field.new(:title, :text),
        ActiveSearch::Index::Field.new(:content, :text),
        ActiveSearch::Index::Field.new(:account_id, :integer),
        ActiveSearch::Index::Field.new(:status, :string),
        ActiveSearch::Index::Field.new(:published_at, :datetime),
        ActiveSearch::Index::Field.new(:featured, :boolean)
      ]
      ActiveSearch::Index::Definition.new(fields: fields)
    end
end
