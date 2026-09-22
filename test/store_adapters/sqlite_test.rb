require "test_helper"

# Named, because establish_connection refuses an anonymous class.
class CacheProbeBase < ActiveRecord::Base
  self.abstract_class = true
end

class SqliteTest < ActiveSupport::TestCase
  searches :articles

  setup do
    skip "SQLite tests require SEARCH_ADAPTER=sqlite" unless store_adapter_name == :sqlite
  end

  test "snippet centers with fewer words before match" do
    long_content = ("word " * 30) + "Ruby programming is great" + (" word" * 30)
    article = Article.create!(title: "Ruby Guide", content: long_content, account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").highlight(
      title: true,
      content: { snippet: { words: 10 } }
    ).results
    result = results.first

    assert_equal "<mark>Ruby</mark> Guide", result.hit.highlight(:title)
    assert_equal "...word word word word <mark>Ruby</mark> programming is great word word...", result.hit.highlight(:content),
      "FTS5 centers a 10-word snippet as 4 before, the match, 5 after"
  end

  test "a five-word snippet keeps two words either side of the match" do
    long_content = ("word " * 30) + "Ruby programming" + (" word" * 30)
    article = Article.create!(title: "The Complete Ruby Programming Guide for Beginners", content: long_content, account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").highlight(
      title: { snippet: { words: 5 } },
      content: { snippet: { words: 5 } }
    ).results
    result = results.first

    assert_equal "The Complete <mark>Ruby</mark> Programming Guide...", result.hit.highlight(:title)
    assert_equal "...word word <mark>Ruby</mark> programming word...", result.hit.highlight(:content)
  end

  test "a snippet marks only the ends where it actually cut" do
    article = Article.create!(title: "Ruby rules", content: "Ruby " + ("word " * 60), account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").highlight(
      title: { snippet: { words: 20 } },
      content: { snippet: { words: 5 } }
    ).results
    hit = results.first.hit

    assert_equal "<mark>Ruby</mark> rules", hit.highlight(:title)
    assert hit.highlight(:content).end_with?("..."), hit.highlight(:content)
    assert_not hit.highlight(:content).start_with?("..."), hit.highlight(:content)
  end

  test "snippet with 10 words on content only" do
    long_content = ("word " * 30) + "Ruby programming" + (" word" * 30)
    article = Article.create!(title: "Guide", content: long_content, account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").highlight(
      content: { snippet: { words: 10 } }
    ).results
    result = results.first

    assert_equal "...word word word word <mark>Ruby</mark> programming word word word word...", result.hit.highlight(:content)
  end

  test "snippet true uses default 20 words" do
    long_content = ("word " * 30) + "Ruby programming" + (" word" * 30)
    article = Article.create!(title: "Guide", content: long_content, account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").highlight(
      content: { snippet: true }
    ).results
    result = results.first

    assert_equal "...word word word word word word word word word <mark>Ruby</mark> programming word word word word word word word word word...", result.hit.highlight(:content)
  end

  test "raises on character-based snippet" do
    article = Article.create!(title: "Ruby Guide", content: "Ruby content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    assert_raises(ActiveSearch::UnsupportedOperationError) do
      ActiveSearch.index(:articles).search("Ruby").highlight(
        content: { snippet: { characters: 100 } }
      ).results
    end
  end

  test "a failed meta delete leaves the document whole rather than half-deleted" do
    article = Article.create!(title: "Half Delete", content: "Content", account_id: 1)
    index = ActiveSearch.index(:articles)
    index.add(article)

    calls = 0
    original = ArticleDocument.method(:where)
    breaking = lambda do |*args, **kwargs|
      calls += 1
      raise ActiveRecord::StatementInvalid, "meta delete refused" if calls == 2
      original.call(*args, **kwargs)
    end

    overriding(ArticleDocument, :where, breaking) do
      assert_raises(ActiveSearch::AdapterError) { index.remove(article) }
    end

    assert_equal 2, calls, "the probe never reached the meta delete"
    assert_results article, index.search("Half"), "the FTS row went while the meta row stayed"
  end

  test "reset_schema_cache drops the column memo a migration invalidates" do
    conn = ArticleDocument.connection
    store = ActiveSearch.index(:articles).store

    conn.create_table(:cache_probe_docs, force: true) { |t| t.integer :account_id }
    conn.execute("CREATE VIRTUAL TABLE cache_probe_docs_fts USING fts5(title)")

    before = store.send(:table_columns, conn, "cache_probe_docs", "cache_probe_docs_fts")
    assert_equal [ [ "account_id" ], [ "title" ] ], before, "control: the memo saw the scratch tables"

    conn.add_column :cache_probe_docs, :status, :string
    store.reset_schema_cache

    meta_columns, = store.send(:table_columns, conn, "cache_probe_docs", "cache_probe_docs_fts")
    assert_includes meta_columns, "status", "the memo survived the reset"
  ensure
    conn.drop_table :cache_probe_docs, if_exists: true
    conn.execute("DROP TABLE IF EXISTS cache_probe_docs_fts")
  end

  test "the column memo cannot serve one database's tables for another's" do
    conn = ArticleDocument.connection
    store = ActiveSearch.index(:articles).store

    conn.create_table(:cache_probe_docs, force: true) { |t| t.integer :account_id }
    conn.execute("CREATE VIRTUAL TABLE cache_probe_docs_fts USING fts5(title)")
    store.send(:table_columns, conn, "cache_probe_docs", "cache_probe_docs_fts")

    CacheProbeBase.establish_connection(adapter: "sqlite3", database: ":memory:")
    other = CacheProbeBase.connection
    other.create_table(:cache_probe_docs) { |t| t.string :other_col }
    other.execute("CREATE VIRTUAL TABLE cache_probe_docs_fts USING fts5(body)")

    assert_equal [ [ "other_col" ], [ "body" ] ],
      store.send(:table_columns, other, "cache_probe_docs", "cache_probe_docs_fts"),
      "the other database was answered from the first one's memo"
  ensure
    store.reset_schema_cache
    CacheProbeBase.remove_connection
    conn.drop_table :cache_probe_docs, if_exists: true
    conn.execute("DROP TABLE IF EXISTS cache_probe_docs_fts")
  end

  test "highlight ordinal follows the FTS table's physical order, not the declaration's" do
    conn = ArticleDocument.connection
    conn.create_table(:hl_probe_docs, force: true) { |t| t.integer :account_id }
    conn.execute("CREATE VIRTUAL TABLE hl_probe_docs_fts USING fts5(content, title)")
    conn.execute("INSERT INTO hl_probe_docs (id, account_id) VALUES (1, 1)")
    conn.execute("INSERT INTO hl_probe_docs_fts (rowid, content, title) VALUES (1, 'body text', 'ruby title')")

    model = Class.new(ApplicationRecord) { self.table_name = "hl_probe_docs" }
    store = ActiveSearch.index(:articles).store
    opts = ActiveSearch::Highlighting::Options.new(title: true)

    select = store.send(:highlight_select, model, "ruby", [ :title ], opts,
      schema_fields: [ :title, :content ], query_context: nil).first
    marked = conn.select_value("SELECT #{select} FROM hl_probe_docs_fts WHERE hl_probe_docs_fts MATCH 'ruby'")

    sentinel_marked = "#{ActiveSearch::Highlighting::STORE_OPEN_MARKER}ruby#{ActiveSearch::Highlighting::STORE_CLOSE_MARKER} title"
    assert_equal sentinel_marked, marked, "the ordinal pointed at the wrong column"
  ensure
    conn.drop_table :hl_probe_docs, if_exists: true
    conn.execute("DROP TABLE IF EXISTS hl_probe_docs_fts")
  end

  test "highlight ordinals are served from the column memo, not a PRAGMA per search" do
    store = ActiveSearch.index(:articles).store
    conn = ArticleDocument.connection
    store.send(:table_columns, conn, "article_documents", "article_documents_fts")

    opts = ActiveSearch::Highlighting::Options.new(title: true)
    pragma_refused = ->(*) { raise "highlight_select re-read the FTS columns instead of the memo" }

    overriding(store, :fts_column_names, pragma_refused) do
      select = store.send(:highlight_select, ArticleDocument, "ruby", [ :title ], opts,
        schema_fields: [ :title, :content ], query_context: nil).first

      assert_match(/highlight\(article_documents_fts, 0,/, select)
    end
  end

  test "a field in both tables answers from the FTS table on a filter-only query" do
    conn = ArticleDocument.connection
    conn.create_table(:dual_probe_docs, force: true) { |t| t.string :title }
    conn.execute("CREATE VIRTUAL TABLE dual_probe_docs_fts USING fts5(title)")
    conn.execute("INSERT INTO dual_probe_docs (id, title) VALUES (1, 'meta value')")
    conn.execute("INSERT INTO dual_probe_docs_fts (rowid, title) VALUES (1, 'fts value')")

    model = Class.new(ApplicationRecord) { self.table_name = "dual_probe_docs" }
    store = ActiveSearch.index(:articles).store

    # No join here: add_field_selection joins the FTS table itself on the no-query path.
    row = store.send(:add_field_selection, model.select("dual_probe_docs.id"), model, [ :title ], query: nil).first

    assert_equal "fts value", row.title, "the meta column shadowed the searched text"
  ensure
    store.reset_schema_cache
    conn.drop_table :dual_probe_docs, if_exists: true
    conn.execute("DROP TABLE IF EXISTS dual_probe_docs_fts")
  end

  test "to_native_query returns ActiveRecord::Relation" do
    relation = ActiveSearch.index(:articles).search("Ruby").filter(account_id: 1)
    raw_query = relation.to_native_query

    assert_kind_of ActiveRecord::Relation, raw_query
  end

  test "to_native_query can be composed with ActiveRecord scopes" do
    article = Article.create!(title: "Composable Ruby", content: "Content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    relation = ActiveSearch.index(:articles).search("Composable")
    raw_query = relation.to_native_query

    result = raw_query.where("1=1").to_a
    assert_equal 1, result.size
  end

  test "to_native_query respects limit" do
    Article.create!(title: "Limit One", content: "Content", account_id: 1).tap { |a| ActiveSearch.index(:articles).add(a) }
    Article.create!(title: "Limit Two", content: "Content", account_id: 1).tap { |a| ActiveSearch.index(:articles).add(a) }

    relation = ActiveSearch.index(:articles).search("Limit").limit(1)
    raw_query = relation.to_native_query

    assert_equal 1, raw_query.to_a.size
  end

  test "to_native_query respects offset" do
    Article.create!(title: "Offset Test", content: "Content", account_id: 1).tap { |a| ActiveSearch.index(:articles).add(a) }
    Article.create!(title: "Offset Test", content: "Content", account_id: 1).tap { |a| ActiveSearch.index(:articles).add(a) }

    all_results = ActiveSearch.index(:articles).search("Offset").to_native_query.to_a
    offset_results = ActiveSearch.index(:articles).search("Offset").offset(1).to_native_query.to_a

    assert_equal all_results.size - 1, offset_results.size
  end

  test "native can add additional conditions" do
    article1 = Article.create!(title: "Modify Test", content: "Content", account_id: 1)
    article2 = Article.create!(title: "Modify Test", content: "Content", account_id: 2)
    [ article1, article2 ].each { |r| ActiveSearch.index(:articles).add(r) }

    results = ActiveSearch.index(:articles).search("Modify").native { |query| query.where!(account_id: 1) }.results
    assert_equal 1, results.total
  end

  test "terms with special characters are escaped" do
    article = Article.create!(title: "Learning C++ programming", content: "C++ is powerful", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("C++").results
    assert_equal 1, results.total
    assert_equal article.id, results.first.id
  end

  test "minus does not act as exclusion operator" do
    article = Article.create!(title: "hello world", content: "greeting", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("hello -world").results
    assert_equal 1, results.total, "sanitised, the minus does not exclude \"world\""
  end

  test "pipe does not act as OR operator" do
    article1 = Article.create!(title: "hello there", content: "greeting", account_id: 1)
    article2 = Article.create!(title: "world news", content: "news", account_id: 1)
    [ article1, article2 ].each { |a| ActiveSearch.index(:articles).add(a) }

    results = ActiveSearch.index(:articles).search("hello | world").results
    assert_equal 0, results.total, "the pipe is stripped, leaving \"hello world\", which requires both"
  end

  test "standalone operators are removed" do
    article = Article.create!(title: "test content", content: "some text", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("test + - |").results
    assert_equal 1, results.total
  end

  test "quoted phrases are preserved" do
    article1 = Article.create!(title: "hello world today", content: "greeting", account_id: 1)
    article2 = Article.create!(title: "world hello", content: "reversed", account_id: 1)
    [ article1, article2 ].each { |a| ActiveSearch.index(:articles).add(a) }

    results = ActiveSearch.index(:articles).search('"hello world"').results
    assert_equal 1, results.total
    assert_equal article1.id, results.first.id
  end

  test "mixed query with special chars and quoted phrases" do
    article = Article.create!(title: "C++ programming basics", content: "learn C++ today", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search('C++ "programming basics"').results
    assert_equal 1, results.total
  end

  test "parentheses in terms are escaped" do
    article = Article.create!(title: "function(x) returns value", content: "code example", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("function(x)").results
    assert_equal 1, results.total
  end

  test "asterisk in terms is escaped" do
    article = Article.create!(title: "pointer *ptr declaration", content: "C code", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("*ptr").results
    assert_equal 1, results.total
  end

  test "caret in terms is escaped" do
    article = Article.create!(title: "regex pattern ^start", content: "regex example", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("^start").results
    assert_equal 1, results.total
  end

  test "colon in terms is escaped" do
    article = Article.create!(title: "time 10:30 meeting", content: "schedule", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("10:30").results
    assert_equal 1, results.total
  end

  private
    # minitest/mock is gone in minitest 6, and a singleton method reaches a private one.
    def overriding(object, name, replacement)
      object.define_singleton_method(name, &replacement)
      yield
    ensure
      object.singleton_class.send(:remove_method, name)
    end
end
