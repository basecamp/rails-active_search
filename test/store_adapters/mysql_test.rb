require "test_helper"

class MysqlTest < ActiveSupport::TestCase
  searches :articles

  setup do
    skip "MySQL tests require SEARCH_ADAPTER=mysql" unless store_adapter_name == :mysql
  end

  # MySQL matches a FULLTEXT index by its whole column list, so an index carrying a scoping column
  # alongside the text ones cannot be reached through the searched fields alone.
  test "an adapter supplies the MATCH columns its FULLTEXT index needs" do
    store = Class.new(ActiveSearch::StoreAdapters::Mysql) do
      def match_columns(index, query_context)
        [ :account_id ] + query_context.fields
      end
      private :match_columns
    end.new

    sql = store.build_query(ActiveSearch.index(:articles), context_for("ruby"), routing: nil).to_sql

    assert_includes sql, "MATCH(`account_id`, `title`, `content`) AGAINST('ruby' IN BOOLEAN MODE)"
  end

  # A scoping column that is in the FULLTEXT index and deliberately not in the store-agnostic
  # declaration, which is what the seam exists for.
  test "an undeclared MATCH column is quoted into the generated SQL" do
    store = Class.new(ActiveSearch::StoreAdapters::Mysql) do
      def match_columns(index, query_context) = [ :tenant_key ] + query_context.fields
      private :match_columns
    end.new

    refute_includes ActiveSearch.index(:articles).definition.field_names.map(&:to_s), "tenant_key"

    sql = store.build_query(ActiveSearch.index(:articles), context_for("ruby"), routing: nil).to_sql

    assert_includes sql, "MATCH(`tenant_key`, `title`, `content`) AGAINST('ruby' IN BOOLEAN MODE)"
  end

  # Routing is resolved centrally from the query's filters, and a scoping adapter has nothing to
  # scope by if it is lost between build_raw_query and apply_search.
  test "the routing value reaches the boolean query" do
    seen = []
    store = Class.new(ActiveSearch::StoreAdapters::Mysql) do
      define_method(:boolean_query) do |query_context, routing: nil|
        seen << routing
        super(query_context, routing: routing)
      end
      private :boolean_query
    end.new

    index = ActiveSearch.index(:records)
    store.build_query(index, records_context(account_id: 7), routing: 7).to_sql
    store.build_query(index, records_context(account_id: [ 7, 9 ]), routing: [ 7, 9 ]).to_sql
    store.build_query(index, records_context, routing: nil).to_sql

    assert_equal [ 7, [ 7, 9 ], nil ], seen
  end

  # Read off the public API rather than made up here, so the two are pinned together.
  test "an adapter's routing is the value the relation resolves" do
    relation = ActiveSearch.index(:records).search("ruby").filter(account_id: 7)

    assert_equal 7, relation.routing
  end

  test "raises error when highlighting is requested" do
    article = Article.create!(title: "Ruby Guide", content: "Ruby content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    assert_raises(ActiveSearch::UnsupportedOperationError) do
      ActiveSearch.index(:articles).search("Ruby").highlight(true).results
    end
  end

  test "raises error when highlight options are provided" do
    article = Article.create!(title: "Ruby Guide", content: "Ruby content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    assert_raises(ActiveSearch::UnsupportedOperationError) do
      ActiveSearch.index(:articles).search("Ruby").highlight(title: true).results
    end
  end

  private
    def context_for(query)
      ActiveSearch.index(:articles).search(query).send(:query_context_with_defaults)
    end

    def records_context(filters = nil)
      relation = ActiveSearch.index(:records).search("ruby")
      relation = relation.filter(**filters) if filters
      relation.send(:query_context_with_defaults)
    end
end
