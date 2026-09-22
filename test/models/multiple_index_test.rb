require "test_helper"

class MultipleIndexTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  searches :comments, :records

  test "index_document indexes to all configured indexes" do
    comment = Comment.create!(body: "Multiple index test", account_id: 1, article_id: 1)
    ActiveSearch.index(:comments).add(comment)

    results = ActiveSearch.index(:comments).search("Multiple index test").results
    assert_equal 1, results.total
    assert_equal comment, results.first

    results = ActiveSearch.index(:records).search("Multiple index test").results
    assert_equal 1, results.total
    assert_equal comment, results.first
  end

  test "remove_document removes from specific index" do
    comment = Comment.create!(body: "To be removed", account_id: 1, article_id: 1)
    ActiveSearch.index(:comments).add(comment)
    ActiveSearch.index(:records).add(comment)

    assert_equal 1, ActiveSearch.index(:comments).search("To be removed").results.total
    assert_equal 1, ActiveSearch.index(:records).search("To be removed").results.total

    ActiveSearch.index(:comments).remove(comment)

    assert_equal 0, ActiveSearch.index(:comments).search("To be removed").results.total
    assert_equal 1, ActiveSearch.index(:records).search("To be removed").results.total

    ActiveSearch.index(:records).remove(comment)
    assert_equal 0, ActiveSearch.index(:records).search("To be removed").results.total
  end

  test "automatic indexing on create indexes to all indexes" do
    perform_enqueued_jobs do
      comment = Comment.create!(body: "Auto indexed multi", account_id: 1, article_id: 1)

      assert_equal 1, ActiveSearch.index(:comments).search("Auto indexed multi").results.total
      assert_equal 1, ActiveSearch.index(:records).search("Auto indexed multi").results.total
    end
  end

  test "automatic removal on destroy removes from all indexes" do
    perform_enqueued_jobs do
      comment = Comment.create!(body: "Will be destroyed", account_id: 1, article_id: 1)

      assert_equal 1, ActiveSearch.index(:comments).search("Will be destroyed").results.total
      assert_equal 1, ActiveSearch.index(:records).search("Will be destroyed").results.total

      comment.destroy!

      assert_equal 0, ActiveSearch.index(:comments).search("Will be destroyed").results.total
      assert_equal 0, ActiveSearch.index(:records).search("Will be destroyed").results.total
    end
  end

  test "each index uses its own serializer" do
    comment = Comment.create!(body: "Different serializers", account_id: 1, article_id: 1)
    ActiveSearch.index(:comments).add(comment)

    comments_results = ActiveSearch.index(:comments).search("Different serializers").results
    assert_equal 1, comments_results.total
    body = Array(comments_results.first.hit.fields[:body]).first
    assert_equal "Different serializers", body
    refute comments_results.first.hit.fields.key?(:record_type)

    content_results = ActiveSearch.index(:records).search("Different serializers").results
    assert_equal 1, content_results.total
    title = Array(content_results.first.hit.fields[:title]).first
    content_body = Array(content_results.first.hit.fields[:body]).first
    record_type = Array(content_results.first.hit.fields[:record_type]).first
    record_id = Array(content_results.first.hit.fields[:record_id]).first
    assert_equal "Comment", title
    assert_equal "Different serializers", content_body
    assert_equal "Comment", record_type
    assert_equal comment.id.to_s, record_id.to_s
  end
end
