require "test_helper"

class ReservedFieldNamesTest < ActiveSupport::TestCase
  test "an Elasticsearch index declaring string :id boots and projects the field" do
    with_store(adapter: :elasticsearch) do
      index = ActiveSearch.define_index(:es_id_shape) do
        text :title
        string :id
      end

      assert_includes index.definition.field_names, :id

      native = index.search("ruby").hit_fields(:id, :title).to_native_query
      assert_includes native[:_source], "id", "the declared id must reach the compiled projection"
    end
  end

  test "a Typesense index declaring string :id is refused, naming the store" do
    assert_reserved(:typesense, :id) { string :id }
  end

  test "a Meilisearch index declaring string :id is refused, naming the store" do
    assert_reserved(:meilisearch, :id) { string :id }
  end

  test "a database index declaring string :id is refused, naming the store" do
    assert_reserved(:sqlite, :id) { string :id }
  end

  test "a database index declaring float :score is refused, naming the store" do
    assert_reserved(:sqlite, :score) { float :score }
  end

  test "the three database adapters answer one reserved set" do
    sets = [ ActiveSearch::StoreAdapters::Sqlite,
             ActiveSearch::StoreAdapters::Mysql,
             ActiveSearch::StoreAdapters::Postgresql ].map(&:reserved_field_names)

    assert_equal [ %i[ id score ] ] * 3, sets
  end

  test "the lexical name pattern still refuses before any store is asked" do
    error = assert_raises(ActiveSearch::ConfigurationError) do
      ActiveSearch::Index::Field.new(:"not a name", :string)
    end

    assert_match(/Invalid field name/, error.message)
  end

  private
    def assert_reserved(adapter, name, &declaration)
      with_store(adapter: adapter) do
        error = assert_raises(ActiveSearch::ConfigurationError) do
          ActiveSearch.define_index(:"#{adapter}_#{name}_shape") do
            text :title
            instance_eval(&declaration)
          end
        end

        assert_match(/Field name :#{name} is reserved on #{adapter}/, error.message)
      end
    end

    def with_store(config)
      swapped = ActiveSearch::Configuration.new
      swapped.apply_store_config(config)
      previous = ActiveSearch.configuration
      ActiveSearch.instance_variable_set(:@configuration, swapped)
      yield
    ensure
      ActiveSearch.instance_variable_set(:@configuration, previous)
    end
end
