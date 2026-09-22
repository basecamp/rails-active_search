require "test_helper"

class AdapterTest < ActiveSupport::TestCase
  searches :articles, :products

  test "store is configured from SEARCH_ADAPTER env var" do
    expected = ENV.fetch("SEARCH_ADAPTER", "sqlite").to_sym
    assert_equal expected, store_adapter_name
  end

  test "ping returns true when database is connected" do
    index = ActiveSearch.index(:articles)
    assert index.store.ping
  end

  test "index adds document to search" do
    article = Article.create!(title: "Hello World", content: "This is a test article", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Hello").results
    assert_equal 1, results.total
    assert_equal article, results.first
  end

  test "remove deletes document from search" do
    article = Article.create!(title: "Delete Me", content: "This will be removed", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Delete").results
    assert_equal 1, results.total

    ActiveSearch.index(:articles).remove(article)
    results = ActiveSearch.index(:articles).search("Delete").results
    assert_equal 0, results.total
  end

  test "remove deletes document via index" do
    article = Article.create!(title: "Remove By Record", content: "Testing remove", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Remove By Record").results
    assert_equal 1, results.total

    index = ActiveSearch.index(:articles)
    index.remove(article)
    results = ActiveSearch.index(:articles).search("Remove By Record").results
    assert_equal 0, results.total
  end

  test "search returns matching documents" do
    article1 = Article.create!(title: "Ruby Programming", content: "Learn Ruby basics", account_id: 1)
    article2 = Article.create!(title: "Python Programming", content: "Learn Python basics", account_id: 1)
    article3 = Article.create!(title: "Ruby Advanced", content: "Advanced Ruby techniques", account_id: 1)

    [ article1, article2, article3 ].each { |r| ActiveSearch.index(:articles).add(r) }

    results = ActiveSearch.index(:articles).search("Ruby").results
    assert_equal 2, results.total

    ids = results.map(&:id)
    assert_includes ids, article1.id
    assert_includes ids, article3.id
    refute_includes ids, article2.id
  end

  test "search with empty query returns all documents" do
    article1 = Article.create!(title: "First Article", content: "Content one", account_id: 1)
    article2 = Article.create!(title: "Second Article", content: "Content two", account_id: 1)

    [ article1, article2 ].each { |r| ActiveSearch.index(:articles).add(r) }

    results = ActiveSearch.index(:articles).search("").results
    assert_equal 2, results.total
  end

  test "search with pagination" do
    5.times do |i|
      article = Article.create!(title: "Article #{i}", content: "Searchable content", account_id: 1)
      ActiveSearch.index(:articles).add(article)
    end

    results = ActiveSearch.index(:articles).search("Searchable").limit(2).results
    assert_equal 5, results.total
    assert_equal 2, results.size

    results = ActiveSearch.index(:articles).search("Searchable").limit(2).offset(2).results
    assert_equal 5, results.total
    assert_equal 2, results.size

    results = ActiveSearch.index(:articles).search("Searchable").limit(2).offset(4).results
    assert_equal 5, results.total
    assert_equal 1, results.size
  end

  test "a float field filters by value and by range" do
    skip "products index is not defined for the database adapters" if
      %i[sqlite mysql postgresql].include?(store_adapter_name)

    cheap = Product.create!(name: "Widget small", description: "Priced low", price: 9.99, category: "tools")
    dear = Product.create!(name: "Widget large", description: "Priced high", price: 199.5, category: "tools")
    [ cheap, dear ].each { |product| ActiveSearch.index(:products).add(product) }
    ActiveSearch.index(:products).store.refresh(:products) rescue nil

    widgets = ActiveSearch.index(:products).search("Widget")

    assert_results cheap, widgets.filter(price: ..50.0)
    assert_results dear, widgets.filter(price: 100.0..)
    assert_results cheap, widgets.filter(price: 9.99)
    assert_results [ cheap, dear ], widgets.filter(price: 1.0..500.0)
  end

  test "next_page? walks a paged search to its end" do
    5.times do |i|
      article = Article.create!(title: "Article #{i}", content: "Searchable content", account_id: 1,
        published_at: Time.utc(2026, 1, 1) + i.days)
      ActiveSearch.index(:articles).add(article)
    end

    query = ActiveSearch.index(:articles).search("Searchable").sort(published_at: :asc).limit(2)

    assert_predicate query.results, :next_page?
    assert_predicate query.offset(2).results, :next_page?
    assert_not_predicate query.offset(4).results, :next_page?
    assert_empty query.offset(5).results
    assert_not_predicate query.offset(5).results, :next_page?
  end

  test "a document whose record was deleted without callbacks still counts towards the total" do
    articles = 3.times.map do |i|
      Article.create!(title: "Article #{i}", content: "Stale content", account_id: 1).tap do |article|
        ActiveSearch.index(:articles).add(article)
      end
    end
    Article.where(id: articles.second.id).delete_all

    results = ActiveSearch.index(:articles).search("Stale").results

    assert_equal 3, results.total
    assert_equal 2, results.size
    assert_equal [ articles.first.id, articles.third.id ].sort, results.map(&:id).sort
  end

  test "a stale document does not shorten the walk through the pages" do
    articles = 6.times.map do |i|
      Article.create!(title: "Article #{i}", content: "Walkable content", account_id: 1,
        published_at: Time.utc(2026, 1, 1) + i.days).tap do |article|
        ActiveSearch.index(:articles).add(article)
      end
    end
    Article.where(id: articles.second.id).delete_all

    query = ActiveSearch.index(:articles).search("Walkable").sort(published_at: :asc).limit(5)
    first_page = query.results

    assert_equal 6, first_page.total
    assert_equal 4, first_page.size
    assert_predicate first_page, :next_page?, "a hydration gap is not the end of the hits"

    last_page = query.offset(5).results

    assert_equal 1, last_page.size
    assert_not_predicate last_page, :next_page?
  end

  test "a stale document in a full last page does not invent a page beyond it" do
    articles = 5.times.map do |i|
      Article.create!(title: "Article #{i}", content: "Countable content", account_id: 1,
        published_at: Time.utc(2026, 1, 1) + i.days).tap do |article|
        ActiveSearch.index(:articles).add(article)
      end
    end
    Article.where(id: articles.second.id).delete_all

    results = ActiveSearch.index(:articles).search("Countable").sort(published_at: :asc).limit(5).results

    assert_equal 5, results.total
    assert_equal 4, results.size
    assert_not_predicate results, :next_page?, "five of five hits were returned, stale or not"
  end

  test "a zero limit reports the total without returning a row" do
    3.times do |i|
      ActiveSearch.index(:articles).add(Article.create!(title: "Article #{i}", content: "Countable content", account_id: 1))
    end

    results = ActiveSearch.index(:articles).search("Countable").limit(0).results

    assert_empty results
    assert_equal 3, results.total
    assert_predicate results, :next_page?
  end

  test "batch with block indexes multiple documents" do
    articles = 3.times.map do |i|
      Article.create!(title: "Batch Article #{i}", content: "Batch content #{i}", account_id: 1)
    end

    index = ActiveSearch.index(:articles)
    index.batch do |batch|
      articles.each do |article|
        batch.add(article)
      end
    end

    results = ActiveSearch.index(:articles).search("Batch").results
    assert_equal 3, results.total
  end

  test "batch with mixed adds and removes" do
    article1 = Article.create!(title: "Keep This", content: "Batch mixed", account_id: 1)
    article2 = Article.create!(title: "Remove This", content: "Batch mixed", account_id: 1)
    ActiveSearch.index(:articles).add(article1)
    ActiveSearch.index(:articles).add(article2)

    results = ActiveSearch.index(:articles).search("Batch mixed").results
    assert_equal 2, results.total

    index = ActiveSearch.index(:articles)
    article3 = Article.create!(title: "Add This", content: "Batch mixed", account_id: 1)

    index.batch do |batch|
      batch.add(article3)
      batch.remove(article2)
    end

    results = ActiveSearch.index(:articles).search("Batch mixed").results
    assert_equal 2, results.total
    ids = results.map(&:id)
    assert_includes ids, article1.id
    assert_includes ids, article3.id
    refute_includes ids, article2.id
  end

  test "batch without block returns batch for manual use" do
    article = Article.create!(title: "Manual Batch", content: "Manual content", account_id: 1)

    index = ActiveSearch.index(:articles)
    batch = index.batch
    batch.add(article)
    batch.flush

    results = ActiveSearch.index(:articles).search("Manual Batch").results
    assert_equal 1, results.total
  end

  test "batch auto-flushes at max_size" do
    index = ActiveSearch.index(:articles)

    articles = 5.times.map do |i|
      Article.create!(title: "Auto Flush #{i}", content: "Auto content", account_id: 1)
    end

    index.batch(max_size: 2) do |batch|
      articles.each do |article|
        batch.add(article)
      end
    end

    results = ActiveSearch.index(:articles).search("Auto Flush").results
    assert_equal 5, results.total
  end

  test "filter by single value" do
    article1 = Article.create!(title: "Account One", content: "Content", account_id: 1, status: "published")
    article2 = Article.create!(title: "Account Two", content: "Content", account_id: 2, status: "published")

    [ article1, article2 ].each { |r| ActiveSearch.index(:articles).add(r) }

    results = ActiveSearch.index(:articles).search("Content").filter(account_id: 1).results
    assert_equal 1, results.total
    assert_equal [ article1.id ], results.map(&:id)
  end

  test "filter by multiple values with IN" do
    article1 = Article.create!(title: "Draft Article", content: "Content", account_id: 1, status: "draft")
    article2 = Article.create!(title: "Published Article", content: "Content", account_id: 1, status: "published")
    article3 = Article.create!(title: "Archived Article", content: "Content", account_id: 1, status: "archived")

    [ article1, article2, article3 ].each { |r| ActiveSearch.index(:articles).add(r) }

    results = ActiveSearch.index(:articles).search("Content").filter(status: [ "draft", "published" ]).results
    assert_equal 2, results.total

    ids = results.map(&:id)
    assert_includes ids, article1.id
    assert_includes ids, article2.id
    refute_includes ids, article3.id
  end

  test "filter with range operator (gte)" do
    article1 = Article.create!(title: "Old Article", content: "Content", account_id: 1, status: "published")
    article2 = Article.create!(title: "New Article", content: "Content", account_id: 5, status: "published")
    article3 = Article.create!(title: "Newest Article", content: "Content", account_id: 10, status: "published")

    [ article1, article2, article3 ].each { |r| ActiveSearch.index(:articles).add(r) }

    results = ActiveSearch.index(:articles).search("Content").filter(account_id: 5..).results
    assert_equal 2, results.total

    ids = results.map(&:id)
    assert_includes ids, article2.id
    assert_includes ids, article3.id
    refute_includes ids, article1.id
  end

  test "reject with range excludes bounded values" do
    article1 = Article.create!(title: "Range One", content: "Content", account_id: 1, status: "published")
    article2 = Article.create!(title: "Range Two", content: "Content", account_id: 2, status: "published")
    article3 = Article.create!(title: "Range Three", content: "Content", account_id: 3, status: "published")

    [ article1, article2, article3 ].each { |r| ActiveSearch.index(:articles).add(r) }

    results = ActiveSearch.index(:articles).search("Content").reject(account_id: 1..2).results
    assert_equal [ article3.id ], results.map(&:id)

    results = ActiveSearch.index(:articles).search("Content").reject(account_id: 1...3).results
    assert_equal [ article3.id ], results.map(&:id)
  end

  test "filter with between range" do
    article1 = Article.create!(title: "Account 1", content: "Content", account_id: 1, status: "published")
    article2 = Article.create!(title: "Account 5", content: "Content", account_id: 5, status: "published")
    article3 = Article.create!(title: "Account 10", content: "Content", account_id: 10, status: "published")

    [ article1, article2, article3 ].each { |r| ActiveSearch.index(:articles).add(r) }

    results = ActiveSearch.index(:articles).search("Content").filter(account_id: 3..7).results
    assert_equal 1, results.total
    assert_equal [ article2.id ], results.map(&:id)
  end

  test "filter combined with text search" do
    article1 = Article.create!(title: "Ruby Programming", content: "Learn Ruby", account_id: 1, status: "published")
    article2 = Article.create!(title: "Ruby Advanced", content: "Advanced Ruby", account_id: 2, status: "published")
    article3 = Article.create!(title: "Python Programming", content: "Learn Python", account_id: 1, status: "published")

    [ article1, article2, article3 ].each { |r| ActiveSearch.index(:articles).add(r) }

    results = ActiveSearch.index(:articles).search("Ruby").filter(account_id: 1).results
    assert_equal 1, results.total
    assert_equal [ article1.id ], results.map(&:id)
  end

  test "filter with empty query" do
    article1 = Article.create!(title: "Published One", content: "Content", account_id: 1, status: "published")
    article2 = Article.create!(title: "Draft One", content: "Content", account_id: 1, status: "draft")

    [ article1, article2 ].each { |r| ActiveSearch.index(:articles).add(r) }

    results = ActiveSearch.index(:articles).filter(status: "published").results
    assert_equal 1, results.total
    assert_equal [ article1.id ], results.map(&:id)
  end

  test "multiple filters combined" do
    article1 = Article.create!(title: "Match", content: "Content", account_id: 1, status: "published")
    article2 = Article.create!(title: "Wrong Account", content: "Content", account_id: 2, status: "published")
    article3 = Article.create!(title: "Wrong Status", content: "Content", account_id: 1, status: "draft")

    [ article1, article2, article3 ].each { |r| ActiveSearch.index(:articles).add(r) }

    results = ActiveSearch.index(:articles).search("Content").filter(account_id: 1, status: "published").results
    assert_equal 1, results.total
    assert_equal [ article1.id ], results.map(&:id)
  end

  test "filter with exclusive range (gt)" do
    article1 = Article.create!(title: "Low", content: "Content", account_id: 1, status: "published")
    article2 = Article.create!(title: "Mid", content: "Content", account_id: 5, status: "published")
    article3 = Article.create!(title: "High", content: "Content", account_id: 10, status: "published")

    [ article1, article2, article3 ].each { |r| ActiveSearch.index(:articles).add(r) }

    results = ActiveSearch.index(:articles).search("Content").filter(account_id: 6..).results
    assert_equal 1, results.total
    assert_equal [ article3.id ], results.map(&:id)
  end

  test "filter with exclusive end range (lt)" do
    article1 = Article.create!(title: "Low", content: "Content", account_id: 1, status: "published")
    article2 = Article.create!(title: "Mid", content: "Content", account_id: 5, status: "published")
    article3 = Article.create!(title: "High", content: "Content", account_id: 10, status: "published")

    [ article1, article2, article3 ].each { |r| ActiveSearch.index(:articles).add(r) }

    results = ActiveSearch.index(:articles).search("Content").filter(account_id: ...5).results
    assert_equal 1, results.total
    assert_equal [ article1.id ], results.map(&:id)
  end

  test "filter with inclusive end range (lte)" do
    article1 = Article.create!(title: "Low", content: "Content", account_id: 1, status: "published")
    article2 = Article.create!(title: "Mid", content: "Content", account_id: 5, status: "published")
    article3 = Article.create!(title: "High", content: "Content", account_id: 10, status: "published")

    [ article1, article2, article3 ].each { |r| ActiveSearch.index(:articles).add(r) }

    results = ActiveSearch.index(:articles).search("Content").filter(account_id: ..5).results
    assert_equal 2, results.total

    ids = results.map(&:id)
    assert_includes ids, article1.id
    assert_includes ids, article2.id
    refute_includes ids, article3.id
  end

  test "reject excludes specified values" do
    article1 = Article.create!(title: "Draft", content: "Content", account_id: 1, status: "draft")
    article2 = Article.create!(title: "Published", content: "Content", account_id: 1, status: "published")
    article3 = Article.create!(title: "Archived", content: "Content", account_id: 1, status: "archived")

    [ article1, article2, article3 ].each { |r| ActiveSearch.index(:articles).add(r) }

    results = ActiveSearch.index(:articles).search("Content").reject(status: [ "draft", "archived" ]).results
    assert_equal 1, results.total
    assert_equal [ article2.id ], results.map(&:id)
  end

  test "reject with array excludes multiple values" do
    article1 = Article.create!(title: "One", content: "Content", account_id: 1, status: "published")
    article2 = Article.create!(title: "Two", content: "Content", account_id: 2, status: "published")
    article3 = Article.create!(title: "Three", content: "Content", account_id: 3, status: "published")

    [ article1, article2, article3 ].each { |r| ActiveSearch.index(:articles).add(r) }

    results = ActiveSearch.index(:articles).search("Content").reject(account_id: [ 1, 3 ]).results
    assert_equal 1, results.total
    assert_equal [ article2.id ], results.map(&:id)
  end

  test "an account_id beyond 32 bits round-trips and filters" do
    big = Article.create!(title: "Bigint", content: "Sized", account_id: 3_000_000_000, status: "published")
    small = Article.create!(title: "Small", content: "Sized", account_id: 42, status: "published")

    [ big, small ].each { |r| ActiveSearch.index(:articles).add(r) }

    assert_results [ big, small ], ActiveSearch.index(:articles).search("Sized"),
      "control: both documents indexed"

    assert_results big, ActiveSearch.index(:articles).search("Sized").filter(account_id: 3_000_000_000)
    assert_results big, ActiveSearch.index(:articles).search("Sized").filter(account_id: 2_147_483_648..)
  end

  test "a filter value casts through the same path as the stored value" do
    article = Article.create!(title: "Cast", content: "Shared", account_id: 42,
      status: "published", published_at: Time.utc(2024, 1, 1, 12, 0, 0))
    ActiveSearch.index(:articles).add(article)

    assert_results article, ActiveSearch.index(:articles).search("Shared").filter(account_id: "42"),
      "a String filter must cast to the stored Integer"
    assert_results article, ActiveSearch.index(:articles).search("Shared").filter(status: :published),
      "a Symbol filter must cast to the stored String"
    assert_results article, ActiveSearch.index(:articles).search("Shared").filter(published_at: "2024-01-01 12:00:00 UTC"..),
      "a String range endpoint must cast to the stored Time"
  end

  test "a datetime filter matches the stored value to the microsecond" do
    precise = Time.utc(2024, 3, 4, 5, 6, 7, 123_456)
    article = Article.create!(title: "Precise", content: "Shared", account_id: 1, published_at: precise)
    ActiveSearch.index(:articles).add(article)

    assert_results article, ActiveSearch.index(:articles).search("Shared").filter(published_at: precise)
  end

  test "a datetime equality refuses a different microsecond in the same second" do
    skip "Solr's serializer keeps whole seconds on both sides; not part of the sub-second fix" if
      store_adapter_name == :solr

    article = Article.create!(title: "Precise", content: "Shared", account_id: 1,
      published_at: Time.utc(2024, 3, 4, 5, 6, 7, 123_456))
    ActiveSearch.index(:articles).add(article)

    assert_results article, ActiveSearch.index(:articles).search("Shared")
      .filter(published_at: Time.utc(2024, 3, 4, 5, 6, 7, 123_456)),
      "control: the microsecond that was stored must match"
    assert_results [], ActiveSearch.index(:articles).search("Shared")
      .filter(published_at: Time.utc(2024, 3, 4, 5, 6, 7, 999_999)),
      "a different microsecond in the stored second must not match"
  end

  test "a datetime range boundary covers the second it names" do
    article = Article.create!(title: "Bounded", content: "Shared", account_id: 1,
      published_at: Time.utc(2024, 3, 4, 5, 6, 7, 123_456))
    ActiveSearch.index(:articles).add(article)

    assert_results article, ActiveSearch.index(:articles).search("Shared")
      .filter(published_at: Time.utc(2024, 3, 4, 5, 6, 7, 500_000)..)
  end

  test "an absent text field reads back nil and leaves the rest searchable" do
    article = Article.create!(title: "Absent Body", content: nil, account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Absent").results
    assert_equal [ article.id ], results.map(&:id),
      "control: the document with no content is findable by its title"

    if store_adapter_name == :manticore
      assert_equal "", results.first.hit.fields[:content],
        "Manticore's floor: attributes have no NULL, so an absent text field reads back as \"\""
    else
      assert_nil results.first.hit.fields[:content]
    end
  end

  test "array members and range endpoints use the same casting path" do
    article = Article.create!(title: "Members", content: "Shared", account_id: 7, status: "published")
    ActiveSearch.index(:articles).add(article)

    assert_results article, ActiveSearch.index(:articles).search("Shared").filter(account_id: [ "7", 8 ])
    assert_results article, ActiveSearch.index(:articles).search("Shared").filter(account_id: "5".."9")
  end

  test "mutating a caller's array after building does not change what executes" do
    mine = Article.create!(title: "Mine", content: "Shared", account_id: 1, status: "published")
    theirs = Article.create!(title: "Theirs", content: "Shared", account_id: 2, status: "published")

    [ mine, theirs ].each { |r| ActiveSearch.index(:articles).add(r) }

    accounts = [ 1 ]
    relation = ActiveSearch.index(:articles).search("Shared").filter(account_id: accounts)

    accounts << 2

    assert_results mine, relation, "the built query must still represent only account 1"
  end

  test "results and to_native_query share portable validation" do
    invalid = -> { ActiveSearch.index(:articles).search("Shared").filter(account_id: "") }

    assert_raises(ActiveSearch::QueryError) { invalid.call }

    unsortable = ActiveSearch.index(:articles).search("Shared")
    assert_raises(ActiveSearch::QueryError) { unsortable.sort(nonexistent: :desc) }
  end

  test "repeated range filters on one field narrow through AND" do
    article1 = Article.create!(title: "Below", content: "Content", account_id: 50, status: "published")
    article2 = Article.create!(title: "Inside", content: "Content", account_id: 150, status: "published")
    article3 = Article.create!(title: "Above", content: "Content", account_id: 250, status: "published")

    [ article1, article2, article3 ].each { |r| ActiveSearch.index(:articles).add(r) }

    assert_results article2,
      ActiveSearch.index(:articles).search("Content").filter(account_id: 100..).filter(account_id: ..200)
  end

  test "repeated conflicting equality filters match nothing" do
    article = Article.create!(title: "Only", content: "Content", account_id: 1, status: "published")
    ActiveSearch.index(:articles).add(article)

    assert_results [],
      ActiveSearch.index(:articles).search("Content").filter(status: "published").filter(status: "draft")
  end

  test "an empty positive filter array matches nothing rather than everything" do
    article = Article.create!(title: "Present", content: "Content", account_id: 1, status: "published")
    ActiveSearch.index(:articles).add(article)

    assert_results article, ActiveSearch.index(:articles).search("Content"),
      "control: the index must hold a matching document for the empty case to mean anything"

    assert_results [], ActiveSearch.index(:articles).search("Content").filter(account_id: [])
  end

  test "an empty array passed to reject excludes nothing" do
    article = Article.create!(title: "Present", content: "Content", account_id: 1, status: "published")
    ActiveSearch.index(:articles).add(article)

    assert_results article, ActiveSearch.index(:articles).search("Content"),
      "control: without the reject, the document is findable"

    assert_results article, ActiveSearch.index(:articles).search("Content").reject(account_id: [])
  end

  test "an empty positive filter array matches nothing on a string field too" do
    article = Article.create!(title: "Present", content: "Content", account_id: 1, status: "published")
    ActiveSearch.index(:articles).add(article)

    assert_results article, ActiveSearch.index(:articles).search("Content").filter(status: "published"),
      "control: the field filters normally with a non-empty value"

    assert_results [], ActiveSearch.index(:articles).search("Content").filter(status: [])
  end

  test "an empty positive filter array matches nothing alongside a matching filter" do
    article = Article.create!(title: "Present", content: "Content", account_id: 1, status: "published")
    ActiveSearch.index(:articles).add(article)

    assert_results article, ActiveSearch.index(:articles).search("Content").filter(account_id: 1),
      "control: the surviving filter matches on its own"

    assert_results [],
      ActiveSearch.index(:articles).search("Content").filter(account_id: 1).filter(status: [])
  end

  test "an unbounded range filter composes with another filter and constrains nothing" do
    article = Article.create!(title: "Unbounded", content: "Content", account_id: 1)
    other = Article.create!(title: "Unbounded", content: "Content", account_id: 2)
    [ article, other ].each { |r| ActiveSearch.index(:articles).add(r) }

    assert_results [ article, other ], ActiveSearch.index(:articles).search("Unbounded").filter(account_id: nil..nil)
    assert_results article,
      ActiveSearch.index(:articles).search("Unbounded").filter(account_id: 1).filter(account_id: nil..nil)
  end

  test "rejecting an unbounded range matches nothing" do
    article = Article.create!(title: "Unbounded", content: "Content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    assert_results article, ActiveSearch.index(:articles).search("Unbounded"),
      "control: the document is findable without the reject"

    assert_results [], ActiveSearch.index(:articles).search("Unbounded").reject(account_id: nil..nil)
  end

  test "rejecting an unbounded range beside another condition negates only the rest" do
    article = Article.create!(title: "Unbounded", content: "Content", account_id: 1, status: "published")
    other = Article.create!(title: "Unbounded", content: "Content", account_id: 2, status: "draft")
    [ article, other ].each { |r| ActiveSearch.index(:articles).add(r) }

    assert_results other,
      ActiveSearch.index(:articles).search("Unbounded").reject(status: "published", account_id: nil..nil)
  end

  test "an empty access-scoping filter array does not leak another tenant's documents" do
    mine = Article.create!(title: "Mine", content: "Content", account_id: 1, status: "published")
    theirs = Article.create!(title: "Theirs", content: "Content", account_id: 2, status: "published")

    [ mine, theirs ].each { |r| ActiveSearch.index(:articles).add(r) }

    assert_results [ mine, theirs ], ActiveSearch.index(:articles).search("Content"),
      "control: both accounts' documents are in the index"

    assert_results [], ActiveSearch.index(:articles).search("Content").filter(account_id: [])
  end

  test "reject combined with filter" do
    article1 = Article.create!(title: "Match", content: "Content", account_id: 1, status: "published")
    article2 = Article.create!(title: "Excluded Status", content: "Content", account_id: 1, status: "draft")
    article3 = Article.create!(title: "Wrong Account", content: "Content", account_id: 2, status: "published")

    [ article1, article2, article3 ].each { |r| ActiveSearch.index(:articles).add(r) }

    results = ActiveSearch.index(:articles).search("Content").filter(account_id: 1).reject(status: "draft").results
    assert_equal 1, results.total
    assert_equal [ article1.id ], results.map(&:id)
  end

  test "filter by boolean true" do
    article1 = Article.create!(title: "Featured", content: "Content", account_id: 1, status: "published", featured: true)
    article2 = Article.create!(title: "Not Featured", content: "Content", account_id: 1, status: "published", featured: false)

    [ article1, article2 ].each { |r| ActiveSearch.index(:articles).add(r) }

    results = ActiveSearch.index(:articles).search("Content").filter(featured: true).results
    assert_equal 1, results.total
    assert_equal [ article1.id ], results.map(&:id)
  end

  test "filter by boolean false" do
    article1 = Article.create!(title: "Featured", content: "Content", account_id: 1, status: "published", featured: true)
    article2 = Article.create!(title: "Not Featured", content: "Content", account_id: 1, status: "published", featured: false)

    [ article1, article2 ].each { |r| ActiveSearch.index(:articles).add(r) }

    results = ActiveSearch.index(:articles).search("Content").filter(featured: false).results
    assert_equal 1, results.total
    assert_equal [ article2.id ], results.map(&:id)
  end

  test "filter by datetime with range (gte)" do
    old_time = 1.week.ago
    recent_time = 1.day.ago

    article1 = Article.create!(title: "Old", content: "Content", account_id: 1, status: "published", published_at: old_time)
    article2 = Article.create!(title: "Recent", content: "Content", account_id: 1, status: "published", published_at: recent_time)

    [ article1, article2 ].each { |r| ActiveSearch.index(:articles).add(r) }

    results = ActiveSearch.index(:articles).search("Content").filter(published_at: 2.days.ago..).results
    assert_equal 1, results.total
    assert_equal [ article2.id ], results.map(&:id)
  end

  test "filter by datetime with between range" do
    very_old = 2.weeks.ago
    middle = 1.week.ago
    recent = 1.day.ago

    article1 = Article.create!(title: "Very Old", content: "Content", account_id: 1, status: "published", published_at: very_old)
    article2 = Article.create!(title: "Middle", content: "Content", account_id: 1, status: "published", published_at: middle)
    article3 = Article.create!(title: "Recent", content: "Content", account_id: 1, status: "published", published_at: recent)

    [ article1, article2, article3 ].each { |r| ActiveSearch.index(:articles).add(r) }

    results = ActiveSearch.index(:articles).search("Content").filter(published_at: 10.days.ago..2.days.ago).results
    assert_equal 1, results.total
    assert_equal [ article2.id ], results.map(&:id)
  end

  test "sort by field with symbol shorthand" do
    old_time = 5.days.ago
    recent_time = 1.day.ago

    article1 = Article.create!(title: "Old Article", content: "Sortable", account_id: 1, published_at: old_time)
    article2 = Article.create!(title: "Recent Article", content: "Sortable", account_id: 1, published_at: recent_time)

    [ article1, article2 ].each { |r| ActiveSearch.index(:articles).add(r) }

    results = ActiveSearch.index(:articles).search("Sortable").sort(:published_at).results
    assert_equal 2, results.total
    assert_equal [ article1.id, article2.id ], results.map(&:id),
      "a bare field name sorts ascending, like ActiveRecord's order"
  end

  test "a bare field name means the same as an explicit ascending direction" do
    articles = [ 3, 1, 2 ].map do |n|
      Article.create!(title: "Bare #{n}", content: "Bare sort", account_id: n).tap do |r|
        ActiveSearch.index(:articles).add(r)
      end
    end

    bare = ActiveSearch.index(:articles).search("Bare sort").sort(:account_id).results.map(&:id)
    asc = ActiveSearch.index(:articles).search("Bare sort").sort(account_id: :asc).results.map(&:id)
    desc = ActiveSearch.index(:articles).search("Bare sort").sort(account_id: :desc).results.map(&:id)

    assert_equal asc, bare
    assert_equal desc, bare.reverse
    assert_equal articles.sort_by(&:account_id).map(&:id), bare
  end

  test "sort by field with explicit direction ascending" do
    old_time = 5.days.ago
    recent_time = 1.day.ago

    article1 = Article.create!(title: "Old Article", content: "Sortable asc", account_id: 1, published_at: old_time)
    article2 = Article.create!(title: "Recent Article", content: "Sortable asc", account_id: 1, published_at: recent_time)

    [ article1, article2 ].each { |r| ActiveSearch.index(:articles).add(r) }

    results = ActiveSearch.index(:articles).search("Sortable asc").sort(published_at: :asc).results
    assert_equal 2, results.total
    assert_equal [ article1.id, article2.id ], results.map(&:id)
  end

  test "sort by field with explicit direction descending" do
    old_time = 5.days.ago
    recent_time = 1.day.ago

    article1 = Article.create!(title: "Old Article", content: "Sortable desc", account_id: 1, published_at: old_time)
    article2 = Article.create!(title: "Recent Article", content: "Sortable desc", account_id: 1, published_at: recent_time)

    [ article1, article2 ].each { |r| ActiveSearch.index(:articles).add(r) }

    results = ActiveSearch.index(:articles).search("Sortable desc").sort(published_at: :desc).results
    assert_equal 2, results.total
    assert_equal [ article2.id, article1.id ], results.map(&:id)
  end

  test "sort_by_relevance ranks the document mentioning the term most first" do
    mentioned_once = Article.create!(title: "Programming basics", content: "Learn Ruby here", account_id: 1)
    mentioned_often = Article.create!(title: "Ruby Programming Ruby", content: "Ruby is great. Ruby is powerful. Learn Ruby today.", account_id: 1)

    [ mentioned_once, mentioned_often ].each { |r| ActiveSearch.index(:articles).add(r) }

    results = ActiveSearch.index(:articles).search("Ruby").sort_by_relevance.results
    assert_equal 2, results.total
    assert_equal mentioned_often.id, results.first.id
  end

  test "search with specific field only matches that field" do
    article1 = Article.create!(title: "Ruby Programming", content: "Learn to code", account_id: 1)
    article2 = Article.create!(title: "Programming Guide", content: "Ruby is great", account_id: 1)

    [ article1, article2 ].each { |r| ActiveSearch.index(:articles).add(r) }

    results = ActiveSearch.index(:articles).search("Ruby", fields: :title).results
    assert_equal 1, results.total
    assert_equal article1.id, results.first.id
  end

  test "search with multiple fields matches any field" do
    article1 = Article.create!(title: "Ruby Programming", content: "Learn to code", account_id: 1)
    article2 = Article.create!(title: "Programming Guide", content: "Ruby is great", account_id: 1)

    [ article1, article2 ].each { |r| ActiveSearch.index(:articles).add(r) }

    results = ActiveSearch.index(:articles).search("Ruby", fields: [ :title, :content ]).results
    assert_equal 2, results.total
  end

  test "Index#add indexes record via as_document" do
    article = Article.create!(title: "Add Test", content: "Content", account_id: 1)

    index = ActiveSearch.index(:articles)
    index.add(article)

    results = index.search("Add Test").results
    assert_equal 1, results.total
  end

  test "Index#remove removes record via as_document" do
    article = Article.create!(title: "Remove Test", content: "Content", account_id: 1)

    index = ActiveSearch.index(:articles)
    index.add(article)

    results = index.search("Remove Test").results
    assert_equal 1, results.total

    index.remove(article)

    results = index.search("Remove Test").results
    assert_equal 0, results.total
  end

  test "Index#batch indexes records" do
    article = Article.create!(title: "Batch Test", content: "Content", account_id: 1)

    index = ActiveSearch.index(:articles)

    index.batch do |batch|
      batch.add(article)
    end

    results = index.search("Batch Test").results
    assert_equal 1, results.total
  end

  test "a filter-only listing returns text field values, not just filter columns" do
    article = Article.create!(title: "Filter Only Title", content: "Filter only content", account_id: 41)
    ActiveSearch.index(:articles).add(article)

    fields = ActiveSearch.index(:articles).filter(account_id: 41).results.first.hit.fields

    assert_equal "Filter Only Title", fields[:title]
    assert_equal "Filter only content", fields[:content]
  end

  test "a filter-only listing accepts highlight without raising" do
    skip "highlight_select is the database adapters' path" unless
      %i[ sqlite postgresql ].include?(store_adapter_name)
    article = Article.create!(title: "Quiet Highlight", content: "Content", account_id: 42)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).filter(account_id: 42).highlight(title: true).results
    hit = results.first.hit

    assert_equal article.id, results.first.id
    assert_nil hit.highlight(:title), "nothing matched, so there is nothing to mark"
    assert_not_includes hit.highlights.keys, :title
  end

  test "result is the AR record with its original id" do
    article = Article.create!(title: "Test Article", content: "Content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Test").results
    result = results.first

    assert_equal article.id, result.id
  end

  test "result provides score as float" do
    article = Article.create!(title: "Test Article", content: "Content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Test").results
    result = results.first

    assert result.hit.score != 0, "Score should be non-zero for a match"
  end

  test "result is the loaded AR record directly" do
    article = Article.create!(title: "Test Article", content: "Content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Test").results
    result = results.first

    assert_equal article, result
  end

  test "results iteration yields records that answer the Resultable interface" do
    article = Article.create!(title: "Iteration Test", content: "Content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Iteration").results

    results.each do |result|
      assert_equal article.id, result.id
      assert result.hit.score != 0, "Score should be non-zero for a match"
      assert_equal "Iteration Test", result.hit.fields[:title]
    end
  end

  test "meilisearch declares its result window, because maxTotalHits truncates silently" do
    adapter = ActiveSearch::StoreAdapters::Meilisearch.new

    assert_not_nil adapter.capabilities.max_result_window,
      "pages past maxTotalHits are lost silently instead of raising ResultWindowExceeded"
  end
end
