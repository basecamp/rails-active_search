require "test_helper"

class EscapingTest < ActiveSupport::TestCase
  def redis_builder
    ActiveSearch::StoreAdapters::RedisSearch.allocate
  end

  def sqlite_builder
    ActiveSearch::StoreAdapters::Sqlite.allocate
  end

  test "sqlite keeps every term when one of them needs quoting" do
    assert_equal '"wi-fi" setup', sqlite_builder.send(:sanitize_fts_query, "wi-fi setup")
    assert_equal '"C++" tutorial guide', sqlite_builder.send(:sanitize_fts_query, "C++ tutorial guide")
  end

  test "sqlite keeps every term when one of them is a quoted phrase" do
    assert_equal '"a phrase" and more', sqlite_builder.send(:sanitize_fts_query, '"a phrase" and more')
  end

  test "sqlite drops a standalone operator without dropping what follows it" do
    assert_equal "ignore", sqlite_builder.send(:sanitize_fts_query, "+++ ignore")
  end

  test "redis escapes a caller supplied backslash so it cannot cancel the next escape" do
    escaped = redis_builder.send(:escape_filter_value, 'draft\\} @ssn:{*} #')

    assert_equal 'draft\\\\\\}\\ \\@ssn\\:\\{\\*\\}\\ \\#', escaped
  end

  test "redis quotes a search term so a backslash or operator cannot act" do
    assert_equal '"a|b"', redis_builder.send(:escape_query, 'a\\|b')
  end

  test "redis keeps numeric range bounds bare and escapes anything else" do
    builder = redis_builder

    assert_equal "@n:[1 5]", builder.send(:build_filter_clause, :n, 1..5)
    assert_equal "@n:[a\\]\\ evil b]", builder.send(:build_filter_clause, :n, "a] evil".."b")
  end

  test "redis does not take the numeric branch for a mixed array" do
    clause = redis_builder.send(:build_filter_clause, :account_id, [ 1, "0 999] | @ssn:{*} #" ])

    assert_not_includes clause, "@ssn:{*}"
  end

  test "redis bounds an offset only window" do
    args = redis_builder.send(:build_search_args, "*", [], [], nil, nil, 20_000, nil)
    limit_at = args.index("LIMIT")

    assert_equal [ "LIMIT", 20_000, ActiveSearch::StoreAdapters::RedisSearch::QueryBuilding::DEFAULT_LIMIT ],
      args[limit_at, 3]
  end

  # ismissing(), which supplies the missing-value predicates and the match-nothing clause, is
  # unavailable without dialect 2.
  test "redis always requests query dialect 2" do
    args = redis_builder.send(:build_search_args, "*", [], [], nil, nil, nil, nil)

    assert_equal [ "DIALECT", 2 ], args.last(2)
  end

  # Typesense honours no escape for a backtick inside its backtick literal, so a value carrying
  # one is refused rather than mangled. A backslash still escapes.
  test "typesense refuses a backtick and escapes a backslash in string literals" do
    assert_equal '`a\\\\c`', ActiveSearch::StoreAdapters::Typesense.allocate.send(:format_value, 'a\\c')

    assert_raises(ActiveSearch::QueryError) do
      ActiveSearch::StoreAdapters::Typesense.allocate.send(:format_value, "a`b")
    end
  end

  test "solr quotes values that are not numeric or boolean" do
    formatted = ActiveSearch::StoreAdapters::Solr.allocate.send(:format_filter_value, :"x] evil")

    assert_equal '"x] evil"', formatted
  end
end
