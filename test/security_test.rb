require "test_helper"

class SecurityTest < ActiveSupport::TestCase
  searches :articles

  test "rejects highlight field names that are not searchable" do
    [ :"title, (SELECT 1) AS x", :nonexistent, :account_id ].each do |field|
      assert_raises(ActiveSearch::QueryError, "expected #{field.inspect} to be rejected") do
        ActiveSearch.index(:articles).search("ruby").highlight(field => true)
      end
    end
  end

  test "rejects snippet sizes that are not bounded positive integers" do
    [ "1) AS x, (SELECT sqlite_version()", 0, -5, 10_001, 1.5, nil ].each do |size|
      assert_raises(ActiveSearch::QueryError, "expected #{size.inspect} to be rejected") do
        ActiveSearch.index(:articles).search("ruby").highlight(title: { snippet: { words: size } })
      end
    end
  end

  test "accepts a bounded positive snippet size" do
    opts = ActiveSearch::Highlighting::FieldOptions.new(snippet: { words: 10 })

    assert_equal 10, opts.snippet_value
  end

  test "rejects markers that are not safe highlight tags" do
    [
      [ "<img src=x onerror=alert(1)>", "</b>" ],
      [ "<script>", "</script>" ],
      [ "<mark onclick=\"x\">", "</mark>" ],
      [ "<mark>" ],
      "<mark>"
    ].each do |markers|
      assert_raises(ActiveSearch::QueryError, "expected #{markers.inspect} to be rejected") do
        ActiveSearch.index(:articles).search("ruby").highlight(title: { markers: markers })
      end
    end
  end

  test "accepts safe highlight tags with class and id attributes" do
    opts = ActiveSearch::Highlighting::FieldOptions.new(
      markers: [ '<mark class="highlight"><span>', "</span></mark>" ]
    )

    assert_equal '<mark class="highlight"><span>', opts.open_marker
  end

  test "rejects unknown highlight formats" do
    assert_raises(ActiveSearch::QueryError) do
      ActiveSearch.index(:articles).search("ruby").highlight(title: { format: :raw })
    end
  end

  test "rejects search fields that are not declared searchable" do
    [ "title); DROP TABLE --", "*", "title^99", :nonexistent_field, :account_id ].each do |field|
      assert_raises(ActiveSearch::QueryError, "expected #{field.inspect} to be rejected") do
        ActiveSearch.index(:articles).search("ruby", fields: [ field ])
      end
    end
  end

  test "rejects sort directions outside asc and desc" do
    [ "desc, evil:asc", "desc; DROP", :sideways ].each do |direction|
      assert_raises(ActiveSearch::QueryError, "expected #{direction.inspect} to be rejected") do
        ActiveSearch.index(:articles).sort(published_at: direction)
      end
    end
  end

  test "normalizes string sort directions" do
    relation = ActiveSearch.index(:articles).sort(published_at: "desc")

    assert_equal [ { published_at: :desc } ], query_context_for(relation).sort
  end

  test "rejects pagination that is not a non-negative integer" do
    [ "5; DROP", -1, "abc" ].each do |value|
      assert_raises(ActiveSearch::QueryError, "expected limit #{value.inspect} to be rejected") do
        ActiveSearch.index(:articles).all.limit(value)
      end

      assert_raises(ActiveSearch::QueryError, "expected offset #{value.inspect} to be rejected") do
        ActiveSearch.index(:articles).all.offset(value)
      end
    end
  end

  test "zero-padded pagination is decimal, not octal" do
    assert_equal 10, query_context_for(ActiveSearch.index(:articles).all.offset("010")).offset
    assert_equal 10, query_context_for(ActiveSearch.index(:articles).all.limit("010")).limit
  end

  test "a sort value with no field name is refused at the relation" do
    [ nil, [ :title ] ].each do |value|
      assert_raises(ActiveSearch::QueryError, "expected sort(#{value.inspect}) to be rejected") do
        ActiveSearch.index(:articles).search("x").sort(value).results
      end
    end
  end

  test "nil is a valid limit and an invalid offset" do
    assert_nothing_raised { ActiveSearch.index(:articles).all.limit(nil) }

    assert_raises(ActiveSearch::QueryError) { ActiveSearch.index(:articles).all.offset(nil) }
  end

  test "rejects filter values that cannot be cast to the declared type" do
    assert_raises(ActiveSearch::QueryError) { ActiveSearch.index(:articles).filter(account_id: "") }
    assert_raises(ActiveSearch::QueryError) { ActiveSearch.index(:articles).filter(published_at: "not a date") }
    assert_raises(ActiveSearch::QueryError) { ActiveSearch.index(:articles).filter(published_at: [ Time.now, "not a date" ]) }
    assert_raises(ActiveSearch::QueryError) { ActiveSearch.index(:articles).filter(account_id: { a: 1 }) }
  end

  test "casting a garbage number matches Active Record rather than rejecting" do
    assert_equal 0, condition_value(ActiveSearch.index(:articles).filter(account_id: "not a number"), :account_id)
    assert_equal 12, condition_value(ActiveSearch.index(:articles).filter(account_id: "12abc"), :account_id)
  end

  test "casts filter values to the declared field type" do
    relation = ActiveSearch.index(:articles).filter(account_id: "42", status: :published)

    assert_equal 42, condition_value(relation, :account_id)
    assert_equal "published", condition_value(relation, :status)
  end

  test "casts filter values inside arrays and ranges" do
    relation = ActiveSearch.index(:articles).filter(account_id: [ "1", 2 ]).filter(published_at: "2024-01-01".."2024-02-01")

    assert_equal [ 1, 2 ], condition_value(relation, :account_id)
    assert_kind_of Time, condition_value(relation, :published_at).begin
  end

  test "casts not-filter values too" do
    relation = ActiveSearch.index(:articles).reject(account_id: "42")

    condition = query_context_for(relation).conditions.for_field(:account_id).first
    assert_equal 42, condition.value
    assert condition.negated?
  end

  test "validated field names cannot be mutated afterwards" do
    fields = [ +"title" ]
    relation = ActiveSearch.index(:articles).search("ruby", fields: fields)

    fields.first << " OR evil"

    assert_equal [ :title ], query_context_for(relation).fields
  end

  test "validated markers cannot be mutated afterwards" do
    opts = ActiveSearch::Highlighting::FieldOptions.new(markers: [ +"<mark>", +"</mark>" ])

    assert_raises(FrozenError) { opts.open_marker << "<img src=x onerror=alert(1)>" }
  end

  test "a window that is not a number is refused rather than becoming zero" do
    index = ActiveSearch.index(:articles)

    [ "abc", "1; DROP TABLE", "", [] ].each do |value|
      assert_raises(ActiveSearch::QueryError, "limit(#{value.inspect})") { index.all.limit(value) }
      assert_raises(ActiveSearch::QueryError, "offset(#{value.inspect})") { index.all.offset(value) }
    end

    assert_nil query_context_for(index.all.limit(nil)).limit
    assert_raises(ActiveSearch::QueryError) { index.all.offset(nil) }

    [ -1, -50 ].each do |value|
      assert_raises(ActiveSearch::QueryError, "limit(#{value.inspect})") { index.all.limit(value) }
      assert_raises(ActiveSearch::QueryError, "offset(#{value.inspect})") { index.all.offset(value) }
    end

    [ -0.9, Rational(-1, 2), BigDecimal("-0.5") ].each do |value|
      assert_raises(ActiveSearch::QueryError, "limit(#{value.inspect})") { index.all.limit(value) }
      assert_raises(ActiveSearch::QueryError, "offset(#{value.inspect})") { index.all.offset(value) }
    end

    assert_equal 2, query_context_for(index.all.offset(2.9)).offset
    assert_equal 2, query_context_for(index.all.limit(2.9)).limit
    assert_equal 5, query_context_for(index.all.limit(5.0)).limit
  end

  test "rejects a malformed default_limit at boot" do
    original = Rails.application.config.active_search.default_limit
    initializer = Rails.application.initializers.find { |i| i.name == "active_search.default_limit" }

    assert initializer, "the default_limit initializer must exist for this to test anything"

    [ -5, "10", 1.5 ].each do |bad|
      Rails.application.config.active_search.default_limit = bad

      error = assert_raises(ActiveSearch::ConfigurationError, "expected #{bad.inspect} to be rejected") do
        initializer.run(Rails.application)
      end
      assert_match(/non-negative Integer or nil/, error.message)
    end

    [ 25, 0, nil ].each do |good|
      Rails.application.config.active_search.default_limit = good
      assert_nothing_raised { initializer.run(Rails.application) }
    end
  ensure
    Rails.application.config.active_search.default_limit = original
  end

  test "typesense refuses to invent a credential" do
    err = assert_raises(ActiveSearch::ConfigurationError) do
      ActiveSearch::StoreAdapters::Typesense.new(nodes: [ { host: "localhost", port: 8108, protocol: "http" } ])
    end

    assert_match(/api_key/, err.message)
  end

  test "escapes hostile document text while rendering only store-marked matches" do
    opts = ActiveSearch::Highlighting::FieldOptions.new
    marked = "<script>alert(1)</script> " \
      "#{ActiveSearch::Highlighting::STORE_OPEN_MARKER}hit#{ActiveSearch::Highlighting::STORE_CLOSE_MARKER} " \
      "<mark>fake</mark>"
    output = ActiveSearch::Highlighting.escape_html(marked, opts)

    assert_includes output, "&lt;script&gt;"
    assert_includes output, "<mark>hit</mark>"
    assert_includes output, "&lt;mark&gt;fake&lt;/mark&gt;"
    assert_predicate output, :html_safe?
  end

  test "typesense refuses a filter value that would break out of its literal" do
    skip "Typesense-specific filter escaping; covered by the typesense run" unless store_adapter_name == :typesense

    mine = Article.create!(title: "one", content: "x", status: "published", account_id: 1)
    other = Article.create!(title: "two", content: "x", status: "secret", account_id: 2)
    index_for(:articles).add(mine)
    index_for(:articles).add(other)

    assert_results mine, index_for(:articles).filter(status: "published")

    payload = "zzz` || status:!=`qqq"
    assert_raises(ActiveSearch::QueryError, "a backtick-bearing filter value must be refused") do
      index_for(:articles).filter(status: payload).results
    end
  end

  test "redis phrase escaping cannot detach the scoping filter" do
    skip "RediSearch phrase escaping; covered by the redis_search run" unless store_adapter_name == :redis_search

    mine = Article.create!(title: "alpha probe", content: "x", account_id: 1)
    other = Article.create!(title: "secret probe", content: "x", account_id: 2)
    index_for(:articles).add(mine)
    index_for(:articles).add(other)

    scoped = index_for(:articles).filter(account_id: 1)
    assert_results mine, scoped.search("probe", fields: [ :title ])

    payload = %q{"x\")) | @account_id:[2 2] | ((\"z"}
    assert_results [], scoped.search(payload, fields: [ :title ])
  end

  test "document preparation strips the highlight sentinels from field values" do
    open_marker = ActiveSearch::Highlighting::STORE_OPEN_MARKER
    close_marker = ActiveSearch::Highlighting::STORE_CLOSE_MARKER
    definition = ActiveSearch.index(:articles).definition

    document = ActiveSearch::Document.new(
      id: "1",
      data: { title: "#{open_marker}evil#{close_marker} ok", content: "safe" },
      definition: definition
    )

    assert_equal "evil ok", document.data[:title]
    refute_includes document.data[:title], open_marker
    refute_includes document.data[:title], close_marker
  end

  test "document preparation leaves ordinary text unchanged" do
    definition = ActiveSearch.index(:articles).definition
    document = ActiveSearch::Document.new(id: "1", data: { title: "plain title", content: "safe" }, definition: definition)

    assert_equal "plain title", document.data[:title]
  end

  test "a routing term cannot carry boolean-mode syntax or be blank" do
    store = ActiveSearch::StoreAdapters::Mysql.new

    assert_equal %q(+"acctone"), store.send(:boolean_term, "acctone")
    assert_equal %q(+"acctone alpha"), store.send(:boolean_term, %q(acctone" alpha))
    assert_equal %q{+("a" "b")}, store.send(:boolean_term, [ "a", "b" ])
    assert_equal %q(-"acctone"), store.send(:boolean_term, "acctone", operator: "-")

    [ nil, "", "  ", %q("), %q(""), [], [ "a", "" ] ].each do |value|
      assert_raises(ActiveSearch::QueryError, "expected #{value.inspect} to be refused") do
        store.send(:boolean_term, value)
      end
    end
  end

  MYSQL_SEARCH_SQL = {
    "plain term" => "SELECT `article_documents`.`article_id`, MATCH(`title`, `content`) AGAINST('ruby' IN BOOLEAN MODE) AS score, `article_documents`.`title`, `article_documents`.`content`, `article_documents`.`account_id`, `article_documents`.`status`, `article_documents`.`published_at`, `article_documents`.`published_on`, `article_documents`.`featured` FROM `article_documents` WHERE (MATCH(`title`, `content`) AGAINST('ruby' IN BOOLEAN MODE)) ORDER BY score DESC LIMIT 25",
    "field subset" => "SELECT `article_documents`.`article_id`, MATCH(`title`) AGAINST('ruby' IN BOOLEAN MODE) AS score, `article_documents`.`title`, `article_documents`.`content`, `article_documents`.`account_id`, `article_documents`.`status`, `article_documents`.`published_at`, `article_documents`.`published_on`, `article_documents`.`featured` FROM `article_documents` WHERE (MATCH(`title`) AGAINST('ruby' IN BOOLEAN MODE)) ORDER BY score DESC LIMIT 25",
    "boolean operators" => "SELECT `article_documents`.`article_id`, MATCH(`title`, `content`) AGAINST('\\\"+account123\\\" \\\"+(run\\\" \\\"jump)\\\"' IN BOOLEAN MODE) AS score, `article_documents`.`title`, `article_documents`.`content`, `article_documents`.`account_id`, `article_documents`.`status`, `article_documents`.`published_at`, `article_documents`.`published_on`, `article_documents`.`featured` FROM `article_documents` WHERE (MATCH(`title`, `content`) AGAINST('\\\"+account123\\\" \\\"+(run\\\" \\\"jump)\\\"' IN BOOLEAN MODE)) ORDER BY score DESC LIMIT 25",
    "sorted and paged" => "SELECT `article_documents`.`article_id`, MATCH(`title`, `content`) AGAINST('ruby' IN BOOLEAN MODE) AS score, `article_documents`.`title`, `article_documents`.`content`, `article_documents`.`account_id`, `article_documents`.`status`, `article_documents`.`published_at`, `article_documents`.`published_on`, `article_documents`.`featured` FROM `article_documents` WHERE (MATCH(`title`, `content`) AGAINST('ruby' IN BOOLEAN MODE)) ORDER BY `article_documents`.`published_at` DESC LIMIT 5 OFFSET 10"
  }.freeze

  test "the search SQL an ordinary caller gets is unchanged by the seams" do
    skip "MySQL MATCH construction; covered by the mysql run" unless store_adapter_name == :mysql

    built = {
      "plain term" => ActiveSearch.index(:articles).search("ruby"),
      "field subset" => ActiveSearch.index(:articles).search("ruby", fields: [ :title ]),
      "boolean operators" => ActiveSearch.index(:articles).search("+account123 +(run jump)"),
      "sorted and paged" => ActiveSearch.index(:articles).search("ruby").sort(published_at: :desc).limit(5).offset(10)
    }

    assert_equal MYSQL_SEARCH_SQL.keys, built.keys, "every captured shape must be rebuilt, or the comparison is empty"

    built.each { |name, relation| assert_equal MYSQL_SEARCH_SQL.fetch(name), relation.to_native_query.to_sql, name }
  end

  # Written out rather than built with quote_column_name, which would assert the fix against itself.
  HOSTILE_MATCH_COLUMNS = {
    "a subquery" => [
      "title, (SELECT account_id FROM article_documents LIMIT 1)",
      "MATCH(`title, (SELECT account_id FROM article_documents LIMIT 1)`)"
    ],
    "a closing backtick" => [ "title`, `x", "MATCH(`title``, ``x`)" ],
    "a UNION behind a comment marker" => [
      "title`) UNION SELECT 1, 2, 3 -- ",
      "MATCH(`title``) UNION SELECT 1, 2, 3 -- `)"
    ],
    "a second AGAINST and a tautology" => [
      "title`) AGAINST('x' IN BOOLEAN MODE) OR 1=1 #",
      "MATCH(`title``) AGAINST('x' IN BOOLEAN MODE) OR 1=1 #`)"
    ]
  }.freeze

  test "a hostile MATCH column from an adapter cannot escape its identifier" do
    skip "MySQL MATCH construction; covered by the mysql run" unless store_adapter_name == :mysql

    HOSTILE_MATCH_COLUMNS.each do |name, (payload, expected)|
      sql = mysql_match_column_store(payload)
        .build_query(ActiveSearch.index(:articles), mysql_query_context("ruby"), routing: nil).to_sql

      assert_includes sql, expected, name
      refute_includes sql, payload, "#{name}: the unescaped payload reached SQL" if payload.include?("`")
    end
  end

  test "match_columns naming nothing is refused" do
    skip "MySQL MATCH construction; covered by the mysql run" unless store_adapter_name == :mysql

    error = assert_raises(ActiveSearch::QueryError) do
      mysql_match_column_store
        .build_query(ActiveSearch.index(:articles), mysql_query_context("ruby"), routing: nil).to_sql
    end
    assert_match(/nothing to MATCH/, error.message)
  end

  test "a blank MATCH column is refused rather than quoted into an empty identifier" do
    skip "MySQL MATCH construction; covered by the mysql run" unless store_adapter_name == :mysql

    [ [ nil ], [ "" ], [ " " ], [ "title", "" ] ].each do |columns|
      error = assert_raises(ActiveSearch::QueryError, "#{columns.inspect} reached SQL") do
        mysql_match_column_store(*columns)
          .build_query(ActiveSearch.index(:articles), mysql_query_context("ruby"), routing: nil).to_sql
      end
      assert_match(/named a blank column/, error.message, columns.inspect)
    end
  end

  test "a hostile routing term cannot escape the boolean query" do
    skip "MySQL boolean-mode composition; covered by the mysql run" unless store_adapter_name == :mysql

    assert_equal %q(+"" -"zzz"), %(+"#{%q(" -"zzz)}"), "the naive interpolation must escape, or there is no hole to close"

    [ "", %q("), nil ].each do |hostile|
      assert_raises(ActiveSearch::QueryError, "expected routing #{hostile.inspect} to be refused") do
        mysql_against_literal(hostile)
      end
    end

    assert_equal %q{+\" -zzz\" +(ruby)}, mysql_against_literal(%q(" -"zzz))
    assert_equal %q{+\"acctone secret\" +(ruby)}, mysql_against_literal(%q(acctone" secret))

    assert_equal %q{+\"acctone\" +(ruby)}, mysql_against_literal("acctone")
  end

  private
    def condition_value(relation, field)
      query_context_for(relation).all_conditions.for_field(field).first.value
    end

    def mysql_query_context(query)
      ActiveSearch.index(:articles).search(query).send(:query_context_with_defaults)
    end

    def mysql_match_column_store(*columns)
      Class.new(ActiveSearch::StoreAdapters::Mysql) do
        define_method(:match_columns) { |index, query_context| columns }
        private :match_columns
      end.new
    end

    def mysql_required_term_store(term)
      Class.new(ActiveSearch::StoreAdapters::Mysql) do
        define_method(:boolean_query) do |query_context, routing: nil|
          "#{boolean_term(term)} +(#{super(query_context, routing: routing)})"
        end
        private :boolean_query
      end.new
    end

    def mysql_against_literal(term, query: "ruby")
      sql = mysql_required_term_store(term)
        .build_query(ActiveSearch.index(:articles), mysql_query_context(query), routing: nil).to_sql

      sql[/AGAINST\('(.*?)' IN BOOLEAN MODE\)/, 1]
    end
end
