require "test_helper"
require "active_support/log_subscriber/test_helper"

class LogSubscriberTest < ActiveSupport::TestCase
  include ActiveSupport::LogSubscriber::TestHelper
  searches :articles

  def setup
    super
    ActiveSearch::LogSubscriber.attach_to(:active_search)
    @article = Article.create!(title: "Logged", content: "Content", account_id: 1)
  end

  test "logs add event" do
    ActiveSearch.index(:articles).add(@article)
    wait

    assert_equal 1, @logger.logged(:debug).size
    assert_match(/ActiveSearch Add/, @logger.logged(:debug).last)
    assert_match(/index: :articles/, @logger.logged(:debug).last)
    assert_match(/document_id: "#{@article.id}"/, @logger.logged(:debug).last)
  end

  test "logs remove event" do
    ActiveSearch.index(:articles).add(@article)
    ActiveSearch.index(:articles).remove(@article)
    wait

    assert_equal 2, @logger.logged(:debug).size
    assert_match(/ActiveSearch Remove/, @logger.logged(:debug).last)
    assert_match(/index: :articles/, @logger.logged(:debug).last)
  end

  test "logs search event with query length and total, never the query itself" do
    ActiveSearch.index(:articles).add(@article)
    ActiveSearch.index(:articles).search("Logged").results
    wait

    search_log = @logger.logged(:debug).find { |m| m.include?("ActiveSearch Search") }
    assert_not_nil search_log, "Expected a search log entry"
    assert_match(/index: :articles/, search_log)
    assert_match(/store_name: :default/, search_log)
    assert_match(/query_length: 6/, search_log)
    assert_match(/total: 1/, search_log)
    assert_no_match(/Logged/, search_log)
  end

  test "logs remove_by_filter event" do
    ActiveSearch.index(:articles).add(@article)
    ActiveSearch.index(:articles).remove_by_filter(account_id: @article.account_id)
    wait

    log = @logger.logged(:debug).find { |m| m.include?("ActiveSearch Remove By Filter") }
    assert_not_nil log, "Expected a remove_by_filter log entry"
    assert_match(/index: :articles/, log)
    assert_match(/removed: /, log)
  end

  test "logs batch flush event" do
    articles = 2.times.map { |i| Article.create!(title: "LogBatch #{i}", content: "C", account_id: 1) }

    ActiveSearch.index(:articles).batch do |batch|
      articles.each { |a| batch.add(a) }
    end
    wait

    batch_log = @logger.logged(:debug).find { |m| m.include?("ActiveSearch Batch") }
    assert_not_nil batch_log, "Expected a batch log entry"
    assert_match(/index: :articles/, batch_log)
    assert_match(/operations: 2/, batch_log)
  end

  test "empty batch produces no log output" do
    ActiveSearch.index(:articles).batch { |_batch| }
    wait

    batch_log = @logger.logged(:debug).find { |m| m.include?("ActiveSearch Batch") }
    assert_nil batch_log
  end

  test "no filter is needed to keep the query out of the log" do
    ActiveSearch.filter_attributes = []

    ActiveSearch.index(:articles).add(@article)
    ActiveSearch.index(:articles).search("Logged").results
    wait

    search_log = @logger.logged(:debug).find { |m| m.include?("ActiveSearch Search") }
    assert_no_match(/Logged/, search_log)
    assert_match(/query_length: 6/, search_log)
  end

  test "filters a payload value that is in filter_attributes" do
    ActiveSearch.filter_attributes = [ :document_id ]

    ActiveSearch.index(:articles).add(@article)
    wait

    add_log = @logger.logged(:debug).find { |m| m.include?("ActiveSearch Add") }
    assert_match(/document_id: "\[FILTERED\]"/, add_log)
  ensure
    ActiveSearch.filter_attributes = []
  end
end
