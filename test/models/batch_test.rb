require "test_helper"

class BatchTest < ActiveSupport::TestCase
  searches :articles

  def index
    ActiveSearch.index(:articles)
  end

  def create_unindexed_article(title:, content: "Content", account_id: 1)
    Article.create!(title: title, content: content, account_id: account_id).tap do |article|
      index.remove(article) rescue nil
    end
  end

  test "batch adds multiple documents" do
    articles = 3.times.map { |i| create_unindexed_article(title: "Batch Add #{i}", content: "Content #{i}") }

    index.batch do |batch|
      articles.each { |article| batch.add(article) }
    end

    results = ActiveSearch.index(:articles).search("Batch Add").results
    assert_equal 3, results.total
  end

  test "batch removes multiple documents" do
    articles = 3.times.map do |i|
      Article.create!(title: "Batch Remove #{i}", content: "Content #{i}", account_id: 1).tap { |r| ActiveSearch.index(:articles).add(r) }
    end

    results = ActiveSearch.index(:articles).search("Batch Remove").results
    assert_equal 3, results.total

    index.batch do |batch|
      articles.each do |article|
        batch.remove(article)
      end
    end

    results = ActiveSearch.index(:articles).search("Batch Remove").results
    assert_equal 0, results.total
  end

  test "batch with max_size nil uses unlimited buffer" do
    articles = 3.times.map { |i| create_unindexed_article(title: "Batch Unlimited #{i}", content: "Content #{i}") }

    batch = index.batch(max_size: nil)
    articles.each { |a| batch.add(a) }
    assert_equal 3, batch.size
    batch.flush

    results = ActiveSearch.index(:articles).search("Batch Unlimited").results
    assert_equal 3, results.total
  end

  test "batch mixing add and remove operations" do
    article1 = Article.create!(title: "Mix Keep", content: "Content", account_id: 1).tap { |r| ActiveSearch.index(:articles).add(r) }
    article2 = Article.create!(title: "Mix Remove", content: "Content", account_id: 1).tap { |r| ActiveSearch.index(:articles).add(r) }
    article3 = create_unindexed_article(title: "Mix New")

    index.batch do |batch|
      batch.remove(article2)
      batch.add(article3)
    end

    results = ActiveSearch.index(:articles).search("Mix").results
    assert_equal 2, results.total
    assert_includes results.map(&:id), article1.id
    assert_includes results.map(&:id), article3.id
    refute_includes results.map(&:id), article2.id
  end

  test "empty batch flush does nothing" do
    index.batch do |batch|
      assert_equal 0, batch.size
    end

    batch = index.batch
    assert_equal 0, batch.size
    batch.flush
    assert_equal 0, batch.size
  end

  test "batch remove_by_id removes document by id" do
    article = Article.create!(title: "Remove By ID", content: "Content", account_id: 1).tap { |r| ActiveSearch.index(:articles).add(r) }

    index.batch do |batch|
      batch.remove_by_id(article.id.to_s)
    end

    results = ActiveSearch.index(:articles).search("Remove By ID").results
    assert_equal 0, results.total
  end

  test "batch size returns number of pending operations" do
    batch = index.batch(max_size: nil)

    assert_equal 0, batch.size

    article = create_unindexed_article(title: "Size Test")
    batch.add(article)

    assert_equal 1, batch.size

    batch.remove_by_id("999")

    assert_equal 2, batch.size
  end

  test "batch auto-flushes at max_size" do
    articles = 3.times.map { |i| create_unindexed_article(title: "AutoFlush #{i}", content: "Content #{i}") }

    batch = index.batch(max_size: 2)
    articles.each { |a| batch.add(a) }
    assert_equal 1, batch.size
    batch.flush

    results = ActiveSearch.index(:articles).search("AutoFlush").results
    assert_equal 3, results.total
  end

  test "a flush that fails below the store keeps the buffer for a replay" do
    articles = 2.times.map { |i| create_unindexed_article(title: "Transport #{i}") }

    batch = index.batch(max_size: nil)
    articles.each { |article| batch.add(article) }

    overriding(index.store, :flush_batch, ->(*, **) { raise IOError, "connection reset" }) do
      assert_raises(IOError) { batch.flush }
    end

    assert_equal 2, batch.size

    batch.flush
    assert_equal 0, batch.size
    assert_equal 2, ActiveSearch.index(:articles).search("Transport").results.total
  end

  private
    def overriding(object, name, replacement)
      object.define_singleton_method(name, &replacement)
      yield
    ensure
      object.singleton_class.send(:remove_method, name)
    end
end
