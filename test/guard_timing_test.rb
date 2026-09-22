require "test_helper"

class GuardTimingTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  searches :proc_guarded_articles

  def reflection = ProcGuardedArticle._index_reflections[:proc_guarded_articles]
  def index = ActiveSearch.index(:proc_guarded_articles)
  def indexed?(title) = index.search(title).results.total.positive?

  test "a live async save enqueues a ReindexJob without freezing the add/remove decision" do
    assert_enqueued_with(job: ActiveSearch::ReindexJob) do
      Article.create!(title: "async probe", content: "c", account_id: 1)
    end
  end

  test "the enqueued job carries the index name as a Symbol, not a flattened String" do
    Article.create!(title: "sym probe", content: "c", account_id: 1)
    reindex = enqueued_jobs.find { |job| job[:job] == ActiveSearch::ReindexJob }
    name = ActiveJob::Arguments.deserialize([ reindex[:args].first ]).first

    assert_equal :articles, name
    assert_instance_of Symbol, name
  end

  test "the remove job also carries the index name as a Symbol, not a flattened String" do
    Article.create!(title: "rm probe", content: "c", account_id: 1).destroy
    remove = enqueued_jobs.find { |job| job[:job] == ActiveSearch::RemoveJob }
    name = ActiveJob::Arguments.deserialize([ remove[:args].first ]).first

    assert_instance_of Symbol, name
  end

  test "a String index name reindexes, so a job enqueued before a deploy is not silently skipped" do
    record = ProcGuardedArticle.create!(title: "deploy safety", content: "c", status: "published")
    index.remove(record)
    assert_not indexed?("deploy safety"), "control: removed before the String-named job runs"

    ActiveSearch::ReindexJob.perform_now("proc_guarded_articles", record)

    assert indexed?("deploy safety"), "a String index name must reach the Symbol-keyed reflection"
  end

  test "update_now removes a record that no longer qualifies, not adds it from a stale decision" do
    record = ProcGuardedArticle.create!(title: "timing", content: "c", status: "published")
    reflection.update_now(record)
    assert indexed?("timing"), "a published record is added"

    record.update!(status: "draft")
    reflection.update_now(record)
    assert_not indexed?("timing"), "the current state removes it, so no stale document survives"
  end
end
