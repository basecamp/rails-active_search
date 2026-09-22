require "test_helper"

class IndexableTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  searches :articles, :comments, :records, :namespaced_tests

  test "Indexable is auto-included via engine" do
    assert Article.include?(ActiveSearch::Indexable)
  end

  test "creating a record indexes it" do
    article = nil
    perform_enqueued_jobs do
      article = Article.create!(title: "Auto Index Test", content: "Should be indexed automatically", account_id: 1)
    end

    results = ActiveSearch.index(:articles).search("Auto Index Test").results
    assert_equal 1, results.total
    assert_equal article, results.first
  end

  test "updating a record reindexes it" do
    perform_enqueued_jobs do
      article = Article.create!(title: "Banana Smoothie", content: "Some content here", account_id: 1)

      results = ActiveSearch.index(:articles).search("Banana").results
      assert_equal 1, results.total

      article.update!(title: "Orange Juice", content: "Different content now")

      results = ActiveSearch.index(:articles).search("Orange").results
      assert_equal 1, results.total

      results = ActiveSearch.index(:articles).search("Banana").results
      assert_equal 0, results.total
    end
  end

  test "destroying a record removes it from index" do
    perform_enqueued_jobs do
      article = Article.create!(title: "To Be Destroyed", content: "Will be removed", account_id: 1)

      results = ActiveSearch.index(:articles).search("To Be Destroyed").results
      assert_equal 1, results.total

      article.destroy!

      results = ActiveSearch.index(:articles).search("To Be Destroyed").results
      assert_equal 0, results.total
    end
  end

  test "async: false indexes synchronously without job" do
    assert_no_enqueued_jobs only: ActiveSearch::ReindexJob do
      Comment.create!(body: "Sync Index Test Comment", account_id: 99, article_id: 1)
    end

    results = ActiveSearch.index(:comments).search("Sync Index Test Comment").filter(account_id: 99).results
    assert_equal 1, results.total
  end

  test "async: false removes synchronously without job" do
    record = Comment.create!(body: "Sync Remove Test Comment", account_id: 98, article_id: 1)

    results = ActiveSearch.index(:comments).search("Sync Remove Test Comment").filter(account_id: 98).results
    assert_equal 1, results.total

    assert_no_enqueued_jobs only: ActiveSearch::RemoveJob do
      record.destroy!
    end

    results = ActiveSearch.index(:comments).search("Sync Remove Test Comment").filter(account_id: 98).results
    assert_equal 0, results.total
  end

  test "async: true (default) enqueues ReindexJob" do
    assert_enqueued_with(job: ActiveSearch::ReindexJob) do
      Article.create!(title: "Async Index Test", content: "Uses job", account_id: 1)
    end
  end

  test "model can have multiple indexes" do
    assert_equal :comments, ActiveSearch.index(:comments).name
    assert_equal :records, ActiveSearch.index(:records).name
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

  test "auto-serializer builds document from schema when no serializer provided" do
    article = Article.create!(title: "Auto Serialized", content: "From schema", account_id: 42, status: "published")

    index = ActiveSearch.index(:articles)
    doc = index.document_for(article)

    assert_equal "Auto Serialized", doc.data[:title]
    assert_equal "From schema", doc.data[:content]
    assert_equal 42, doc.data[:account_id]
    assert_equal "published", doc.data[:status]
  end

  test "suppress_indexing blocks indexing within block" do
    unique_id = "wibble#{SecureRandom.hex(8)}"
    perform_enqueued_jobs do
      Article.suppress_indexing do
        Article.create!(title: unique_id, content: "Should not be indexed", account_id: 1)
      end
    end

    results = ActiveSearch.index(:articles).search(unique_id).results
    assert_equal 0, results.total
  end

  test "suppress_indexing restores indexing after block" do
    inside_id = "plugh#{SecureRandom.hex(8)}"
    outside_id = "qwerty#{SecureRandom.hex(8)}"

    perform_enqueued_jobs do
      Article.suppress_indexing do
        Article.create!(title: inside_id, content: "Suppressed", account_id: 1)
      end
      Article.create!(title: outside_id, content: "Not suppressed", account_id: 1)
    end

    results = ActiveSearch.index(:articles).search(inside_id).results
    assert_equal 0, results.total

    results = ActiveSearch.index(:articles).search(outside_id).results
    assert_equal 1, results.total
  end

  test "a rolled back suppressed save does not suppress the record's next save" do
    article = nil
    unique_id = "rollback#{SecureRandom.hex(8)}"

    perform_enqueued_jobs do
      Article.suppress_indexing do
        ActiveRecord::Base.transaction do
          article = Article.create!(title: "Rolled back", content: "c", account_id: 1)
          raise ActiveRecord::Rollback
        end
      end

      article = Article.create!(title: unique_id, content: "c", account_id: 1)
    end

    assert_equal 1, ActiveSearch.index(:articles).search(unique_id).results.total,
      "the next save inherited suppression from a save that never committed"
  end

  test "suppress_indexing does not suppress a destroy" do
    unique_id = "destroyed#{SecureRandom.hex(8)}"
    article = nil

    perform_enqueued_jobs do
      article = Article.create!(title: unique_id, content: "c", account_id: 1)
      assert_equal 1, ActiveSearch.index(:articles).search(unique_id).results.total, "control: indexed"

      Article.suppress_indexing { article.destroy! }
    end

    assert_equal 0, ActiveSearch.index(:articles).search(unique_id).results.total
  end

  test "suppress_indexing is thread-safe" do
    threads = 2.times.map do |i|
      Thread.new do
        if i == 0
          Article.suppress_indexing do
            sleep 0.1  # Ensure overlap with other thread
            assert Article.indexing_suppressed?
          end
        else
          sleep 0.05
          refute Article.indexing_suppressed?  # Other thread should not be affected
        end
      end
    end
    threads.each(&:join)
  end

  test "dirty tracking triggers reindex when content changes" do
    article = nil
    perform_enqueued_jobs do
      article = Article.create!(title: "Dirty Test", content: "Original", account_id: 1)
    end

    assert_enqueued_with(job: ActiveSearch::ReindexJob) do
      article.update!(content: "Changed content")
    end
  end

  test "a save that changes no column still reindexes" do
    article = nil
    perform_enqueued_jobs do
      article = Article.create!(title: "No Change Test", content: "Original", account_id: 1)
    end

    assert_enqueued_jobs 2, only: ActiveSearch::ReindexJob do
      article.save!
    end
  end

  test "record saved in suppress block can be indexed on subsequent save" do
    unique_id = "suppress_then_save_#{SecureRandom.hex(8)}"

    perform_enqueued_jobs do
      article = Article.suppress_indexing do
        Article.create!(title: unique_id, content: "Initially suppressed", account_id: 1)
      end

      results = ActiveSearch.index(:articles).search(unique_id).results
      assert_equal 0, results.total

      article.update!(content: "Now indexable")
    end

    results = ActiveSearch.index(:articles).search(unique_id).results
    assert_equal 1, results.total
  end

  test "an unindexed model has no search methods at all" do
    assert_raises(NoMethodError) { Author.search("anything") }

    assert_not Author.respond_to?(:search)
    assert_not Author.respond_to?(:suppress_indexing)
    assert_not Author.respond_to?(:indexing_suppressed?)
    assert_not Author.new.respond_to?(:hit)
    assert_not Author.respond_to?(:_index_reflections)
  end

  test "an indexed model receives all of them" do
    assert_respond_to Article, :search
    assert_respond_to Article, :suppress_indexing
    assert_respond_to Article, :indexing_suppressed?
    assert_respond_to Article.new, :hit
    assert_respond_to Article, :_index_reflections
  end

  test "has_search is the only globally available method" do
    assert_respond_to Author, :has_search,
      "the opt-in has to be reachable on a model that has not opted in"
  end

  test ".search with invalid index: raises ConfigurationError" do
    error = assert_raises(ActiveSearch::ConfigurationError) do
      Article.search("anything", index: :nonexistent)
    end

    assert_match "Article has no search index :nonexistent", error.message
  end

  test "a model can search each index it declares" do
    assert_equal :articles, Article.search("anything").index.name
    assert_equal :namespaced_tests, Article.search("anything", index: :namespaced_tests).index.name
  end

  test "a named index is reachable without going through a model" do
    assert_kind_of ActiveSearch::Index, ActiveSearch.index(:articles)
    assert_kind_of ActiveSearch::Index, ActiveSearch.index(:namespaced_tests)
  end
end

class GuardedIndexableTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  searches :guarded_articles, :unless_guarded_articles, :proc_guarded_articles

  test "if guard skips indexing when condition is false" do
    article = GuardedArticle.create!(title: "Guarded If False", content: "Should not index", should_index: false)

    results = ActiveSearch.index(:guarded_articles).search("Guarded If False").results
    assert_equal 0, results.total

    article.update!(should_index: true, content: "Now should index")

    results = ActiveSearch.index(:guarded_articles).search("Guarded If False").results
    assert_equal 1, results.total
  end

  test "if guard allows indexing when condition is true" do
    article = GuardedArticle.create!(title: "Guarded If True", content: "Should index", should_index: true)

    results = ActiveSearch.index(:guarded_articles).search("Guarded If True").results
    assert_equal 1, results.total
  end

  test "if guard removes stale document when condition becomes false on update" do
    article = GuardedArticle.create!(title: "If Guard Stale", content: "Should index", should_index: true)

    results = ActiveSearch.index(:guarded_articles).search("If Guard Stale").results
    assert_equal 1, results.total

    article.update!(should_index: false)

    results = ActiveSearch.index(:guarded_articles).search("If Guard Stale").results
    assert_equal 0, results.total
  end

  test "unless guard skips indexing when condition is true" do
    article = UnlessGuardedArticle.create!(title: "Guarded Unless True", content: "Should not index", skip_indexing: true)

    results = ActiveSearch.index(:unless_guarded_articles).search("Guarded Unless True").results
    assert_equal 0, results.total

    article.update!(skip_indexing: false, content: "Now should index")

    results = ActiveSearch.index(:unless_guarded_articles).search("Guarded Unless True").results
    assert_equal 1, results.total
  end

  test "unless guard allows indexing when condition is false" do
    article = UnlessGuardedArticle.create!(title: "Guarded Unless False", content: "Should index", skip_indexing: false)

    results = ActiveSearch.index(:unless_guarded_articles).search("Guarded Unless False").results
    assert_equal 1, results.total
  end

  test "add_if prevents indexing when condition is false" do
    article = ProcGuardedArticle.create!(title: "Add If Draft", content: "Content", status: "draft")

    results = ActiveSearch.index(:proc_guarded_articles).search("Add If Draft").results
    assert_equal 0, results.total
  end

  test "add_if allows indexing when condition is true" do
    article = ProcGuardedArticle.create!(title: "Add If Published", content: "Content", status: "published")

    results = ActiveSearch.index(:proc_guarded_articles).search("Add If Published").results
    assert_equal 1, results.total
  end

  test "add_if indexes on update when condition becomes true" do
    article = ProcGuardedArticle.create!(title: "Add If Update", content: "Content", status: "draft")

    results = ActiveSearch.index(:proc_guarded_articles).search("Add If Update").results
    assert_equal 0, results.total

    article.update!(status: "published")

    results = ActiveSearch.index(:proc_guarded_articles).search("Add If Update").results
    assert_equal 1, results.total
  end

  test "add_if removes stale document when condition becomes false on update" do
    article = ProcGuardedArticle.create!(title: "Stale Row Test", content: "Content", status: "published")

    results = ActiveSearch.index(:proc_guarded_articles).search("Stale Row Test").results
    assert_equal 1, results.total

    article.update!(status: "draft")

    results = ActiveSearch.index(:proc_guarded_articles).search("Stale Row Test").results
    assert_equal 0, results.total
  end

  test "remove_if prevents removal when condition is false" do
    article = ProcGuardedArticle.create!(title: "Remove If Blocked", content: "Content", status: "published")

    results = ActiveSearch.index(:proc_guarded_articles).search("Remove If Blocked").results
    assert_equal 1, results.total

    article.update!(status: "archived")
    article.destroy!

    results = ActiveSearch.index(:proc_guarded_articles).search("Remove If Blocked").results
    assert_equal 1, results.total
  end

  test "remove_if allows removal when condition is true" do
    article = ProcGuardedArticle.create!(title: "Remove If Allowed", content: "Content", status: "published")

    results = ActiveSearch.index(:proc_guarded_articles).search("Remove If Allowed").results
    assert_equal 1, results.total

    article.destroy!

    results = ActiveSearch.index(:proc_guarded_articles).search("Remove If Allowed").results
    assert_equal 0, results.total
  end
end

class DocumentValidationTest < ActiveSupport::TestCase
  Field = ActiveSearch::Index::Field

  def build_definition(&block)
    fields = []
    block.call(fields)
    ActiveSearch::Index::Definition.new(fields: fields)
  end

  test "document casts integer type" do
    definition = build_definition do |f|
      f << Field.new(:title, :text)
      f << Field.new(:count, :integer)
    end

    doc = ActiveSearch::Document.new(id: "1", data: { title: "Test", count: 42 }, definition: definition)
    assert_equal 42, doc.data[:count]

    doc = ActiveSearch::Document.new(id: "1", data: { title: "Test", count: "42" }, definition: definition)
    assert_equal 42, doc.data[:count]

    doc = ActiveSearch::Document.new(id: "1", data: { title: "Test", count: "not a number" }, definition: definition)
    assert_equal 0, doc.data[:count]
  end

  test "document casts boolean type" do
    definition = build_definition do |f|
      f << Field.new(:title, :text)
      f << Field.new(:active, :boolean)
    end

    doc = ActiveSearch::Document.new(id: "1", data: { title: "Test", active: true }, definition: definition)
    assert_equal true, doc.data[:active]

    doc = ActiveSearch::Document.new(id: "1", data: { title: "Test", active: "true" }, definition: definition)
    assert_equal true, doc.data[:active]

    doc = ActiveSearch::Document.new(id: "1", data: { title: "Test", active: "false" }, definition: definition)
    assert_equal false, doc.data[:active]

    doc = ActiveSearch::Document.new(id: "1", data: { title: "Test", active: 0 }, definition: definition)
    assert_equal false, doc.data[:active]
  end

  test "document casts text type" do
    definition = build_definition do |f|
      f << Field.new(:title, :text)
    end

    doc = ActiveSearch::Document.new(id: "1", data: { title: "Hello" }, definition: definition)
    assert_equal "Hello", doc.data[:title]

    doc = ActiveSearch::Document.new(id: "1", data: { title: 123 }, definition: definition)
    assert_equal "123", doc.data[:title]
  end

  test "document allows nil values" do
    definition = build_definition do |f|
      f << Field.new(:title, :text)
      f << Field.new(:count, :integer)
    end

    doc = ActiveSearch::Document.new(id: "1", data: { title: "Test", count: nil }, definition: definition)
    assert_nil doc.data[:count]
  end
end
