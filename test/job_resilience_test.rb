require "test_helper"

class JobResilienceTest < ActiveSupport::TestCase
  searches :articles

  test "a connection failure during deserialization is not discarded" do
    article = Article.create!(title: "JobRes", content: "text", account_id: 1)
    serialized = ActiveSearch::ReindexJob.new("articles", article).serialize

    with_unreachable_database do
      assert_raises(StandardError, "the job swallowed a retryable failure as a deleted record") do
        ActiveJob::Base.execute(serialized)
      end
    end
  end

  test "a genuinely deleted record is still discarded" do
    article = Article.create!(title: "JobResGone", content: "text", account_id: 1)
    serialized = ActiveSearch::ReindexJob.new("articles", article).serialize
    article.delete

    assert_nothing_raised { ActiveJob::Base.execute(serialized) }
  end

  test "a record gone by GlobalID's own RecordNotFound is discarded too" do
    article = Article.create!(title: "JobResGid", content: "text", account_id: 1)
    serialized = ActiveSearch::ReindexJob.new("articles", article).serialize
    article.delete

    with_locator_raising GlobalID::Locator::RecordNotFound, "gone" do
      assert_nothing_raised { ActiveJob::Base.execute(serialized) }
    end
  end

  private
    def with_unreachable_database(&block)
      with_locator_raising ActiveRecord::ConnectionNotEstablished, "failover in progress", &block
    end

    def with_locator_raising(exception, message)
      singleton = GlobalID::Locator.singleton_class
      singleton.alias_method :__finding_tests_locate, :locate
      GlobalID::Locator.define_singleton_method(:locate) do |*args, **kwargs|
        raise exception, message
      end
      yield
    ensure
      singleton.alias_method :locate, :__finding_tests_locate
      singleton.remove_method :__finding_tests_locate
    end
end
