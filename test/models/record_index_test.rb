require "test_helper"

class RecordIndexTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  searches :articles, :namespaced_tests

  test "index_name returns configured name" do
    assert_equal :articles, ActiveSearch.index(:articles).name
  end

  test "index_document indexes a document" do
    article = Article.create!(title: "Test", content: "Content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Test").results
    assert_equal 1, results.total
    assert_equal article, results.first
  end

  test "remove_document removes a document" do
    article = Article.create!(title: "Test", content: "Content", account_id: 1)
    ActiveSearch.index(:articles).add(article)
    ActiveSearch.index(:articles).remove(article)

    results = ActiveSearch.index(:articles).search("Test").results
    assert_equal 0, results.total
  end

  test "search queries the index" do
    article = Article.create!(title: "Searchable Title", content: "Content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Searchable").results
    assert_equal 1, results.total
  end

  test "automatic indexing on create" do
    perform_enqueued_jobs do
      article = Article.create!(title: "Auto indexed", content: "Content", account_id: 1)

      results = ActiveSearch.index(:articles).search("Auto indexed").results
      assert_equal 1, results.total
      assert_equal article, results.first
    end
  end

  test "automatic indexing on update" do
    perform_enqueued_jobs do
      article = Article.create!(title: "Pineapple", content: "Content", account_id: 1)

      results = ActiveSearch.index(:articles).search("Pineapple").results
      assert_equal 1, results.total

      article.update!(title: "Coconut")

      results = ActiveSearch.index(:articles).search("Coconut").results
      assert_equal 1, results.total

      results = ActiveSearch.index(:articles).search("Pineapple").results
      assert_equal 0, results.total
    end
  end

  test "automatic removal on destroy" do
    perform_enqueued_jobs do
      article = Article.create!(title: "Will be destroyed", content: "Content", account_id: 1)

      results = ActiveSearch.index(:articles).search("Will be destroyed").results
      assert_equal 1, results.total

      article.destroy!

      results = ActiveSearch.index(:articles).search("Will be destroyed").results
      assert_equal 0, results.total
    end
  end

  test "filter by integer" do
    perform_enqueued_jobs do
      article1 = Article.create!(title: "First", content: "Content", account_id: 1)
      article2 = Article.create!(title: "Second", content: "Content", account_id: 2)

      results = ActiveSearch.index(:articles).filter(account_id: 1).results
      assert_equal 1, results.total
      assert_equal article1, results.first

      results = ActiveSearch.index(:articles).filter(account_id: 2).results
      assert_equal 1, results.total
      assert_equal article2, results.first
    end
  end

  test "filter by boolean" do
    article1 = Article.create!(title: "Featured", content: "Content", account_id: 1, featured: true)
    article2 = Article.create!(title: "Not featured", content: "Content", account_id: 1, featured: false)

    ActiveSearch.index(:articles).add(article1)
    ActiveSearch.index(:articles).add(article2)

    results = ActiveSearch.index(:articles).filter(featured: true).results
    assert_equal 1, results.total
    assert_equal article1, results.first

    results = ActiveSearch.index(:articles).filter(featured: false).results
    assert_equal 1, results.total
    assert_equal article2, results.first
  end

  test "filter by datetime comparison" do
    article1 = Article.create!(title: "Old", content: "Content", account_id: 1, published_at: 1.week.ago)
    article2 = Article.create!(title: "New", content: "Content", account_id: 1, published_at: 1.day.ago)

    ActiveSearch.index(:articles).add(article1)
    ActiveSearch.index(:articles).add(article2)

    results = ActiveSearch.index(:articles).filter(published_at: 3.days.ago..).results
    assert_equal 1, results.total
    assert_equal article2, results.first
  end

  test "filter by datetime array (IN clause)" do
    time1 = 1.week.ago.change(usec: 0)
    time2 = 1.day.ago.change(usec: 0)
    time3 = 1.hour.ago.change(usec: 0)

    article1 = Article.create!(title: "Old", content: "Content", account_id: 1, published_at: time1)
    article2 = Article.create!(title: "Recent", content: "Content", account_id: 1, published_at: time2)
    article3 = Article.create!(title: "New", content: "Content", account_id: 1, published_at: time3)

    [ article1, article2, article3 ].each { |r| ActiveSearch.index(:articles).add(r) }

    results = ActiveSearch.index(:articles).filter(published_at: [ time1, time2 ]).results
    assert_equal 2, results.total
    assert_includes results, article1
    assert_includes results, article2
    refute_includes results, article3
  end

  test "reject by datetime" do
    time1 = 1.week.ago.change(usec: 0)
    time2 = 1.day.ago.change(usec: 0)

    article1 = Article.create!(title: "Old", content: "Content", account_id: 1, published_at: time1)
    article2 = Article.create!(title: "New", content: "Content", account_id: 1, published_at: time2)

    [ article1, article2 ].each { |r| ActiveSearch.index(:articles).add(r) }

    results = ActiveSearch.index(:articles).reject(published_at: [ time1 ]).results
    assert_equal 1, results.total
    assert_equal article2, results.first
  end

  test "store can be accessed from index instance" do
    assert_kind_of ActiveSearch::StoreAdapters::Base, ActiveSearch.index(:articles).store
  end

  test "remove deletes document from index" do
    article = Article.create!(title: "Will Remove", content: "Content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Will Remove").results
    assert_equal 1, results.total

    ActiveSearch.index(:articles).remove(article)

    results = ActiveSearch.index(:articles).search("Will Remove").results
    assert_equal 0, results.total
  end

  test "remove_by_id deletes by id directly" do
    article = Article.create!(title: "Remove By ID Direct", content: "Content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Remove By ID Direct").results
    assert_equal 1, results.total

    ActiveSearch.index(:articles).remove_by_id(article.id.to_s)

    results = ActiveSearch.index(:articles).search("Remove By ID Direct").results
    assert_equal 0, results.total
  end

  test "reindex_later enqueues job" do
    article = Article.create!(title: "Add Later Test", content: "Content", account_id: 1)
    ActiveSearch.index(:articles).remove(article) rescue nil

    assert_enqueued_with(job: ActiveSearch::ReindexJob) do
      ActiveSearch.index(:articles).reindex_later(article)
    end

    perform_enqueued_jobs

    results = ActiveSearch.index(:articles).search("Add Later Test").results
    assert_equal 1, results.total
  end

  test "remove_later enqueues job" do
    article = Article.create!(title: "Remove Later Test", content: "Content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Remove Later Test").results
    assert_equal 1, results.total

    assert_enqueued_with(job: ActiveSearch::RemoveJob) do
      ActiveSearch.index(:articles).remove_later(article)
    end

    perform_enqueued_jobs

    results = ActiveSearch.index(:articles).search("Remove Later Test").results
    assert_equal 0, results.total
  end

  test "id_for returns source id" do
    article = Article.create!(title: "ID Test", content: "Content", account_id: 1)

    assert_equal article.id.to_s, ActiveSearch.index(:articles).id_for(article)
  end

  test "document_for returns document with data" do
    article = Article.create!(title: "Doc Test", content: "Doc Content", account_id: 42)

    doc = ActiveSearch.index(:articles).document_for(article)

    assert_equal article.id.to_s, doc.id
    assert_equal "Doc Test", doc.data[:title]
    assert_equal "Doc Content", doc.data[:content]
    assert_equal 42, doc.data[:account_id]
  end

  test "filter by array of integers (IN clause)" do
    perform_enqueued_jobs do
      article1 = Article.create!(title: "Account One", content: "Content", account_id: 1)
      article2 = Article.create!(title: "Account Two", content: "Content", account_id: 2)
      article3 = Article.create!(title: "Account Three", content: "Content", account_id: 3)

      results = ActiveSearch.index(:articles).filter(account_id: [ 1, 2 ]).results
      assert_equal 2, results.total
      assert_includes results.map(&:id), article1.id
      assert_includes results.map(&:id), article2.id
      refute_includes results.map(&:id), article3.id
    end
  end

  test "filter by string field" do
    article1 = Article.create!(title: "Published Article", content: "Content", account_id: 1, status: "published")
    article2 = Article.create!(title: "Draft Article", content: "Content", account_id: 1, status: "draft")

    ActiveSearch.index(:articles).add(article1)
    ActiveSearch.index(:articles).add(article2)

    results = ActiveSearch.index(:articles).filter(status: "published").results
    assert_equal 1, results.total
    assert_equal article1.id, results.first.id

    results = ActiveSearch.index(:articles).filter(status: "draft").results
    assert_equal 1, results.total
    assert_equal article2.id, results.first.id
  end

  test "filter by integer range" do
    article1 = Article.create!(title: "Low Account", content: "Content", account_id: 1)
    article2 = Article.create!(title: "High Account", content: "Content", account_id: 100)

    ActiveSearch.index(:articles).add(article1)
    ActiveSearch.index(:articles).add(article2)

    results = ActiveSearch.index(:articles).filter(account_id: 50..).results
    assert_equal 1, results.total
    assert_equal article2.id, results.first.id

    results = ActiveSearch.index(:articles).filter(account_id: ..50).results
    assert_equal 1, results.total
    assert_equal article1.id, results.first.id
  end
end
