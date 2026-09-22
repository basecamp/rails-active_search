require "test_helper"

class ReindexTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  searches :articles, :guarded_articles, :comments, :records

  test "reindex writes a record whose guards pass" do
    article = GuardedArticle.create!(title: "Qualifying", content: "content", should_index: true)
    ActiveSearch.index(:guarded_articles).remove(article)
    refresh_guarded
    assert_results [], guarded_search, "control: the document is gone"

    article.reindex
    refresh_guarded

    assert_results article, guarded_search
  end

  test "reindex removes a record whose guards now reject it" do
    article = GuardedArticle.create!(title: "Qualifying", content: "content", should_index: true)
    refresh_guarded
    assert_results article, guarded_search, "control: it was indexed while it qualified"

    article.update_columns(should_index: false)
    article.reindex
    refresh_guarded

    assert_results [], guarded_search
  end

  test "reindex follows the model's async setting" do
    article = Article.create!(title: "Async", content: "content", account_id: 1)

    assert_enqueued_with(job: ActiveSearch::ReindexJob) { article.reindex }

    guarded = GuardedArticle.create!(title: "Sync", content: "content", should_index: true)
    assert_no_enqueued_jobs(only: ActiveSearch::ReindexJob) { guarded.reindex }
  end

  test "a commit that changes no column still reindexes" do
    comment = Comment.create!(body: "Original", account_id: 1)
    refresh_comments
    assert_results comment, comment_search("Original"), "control: the create indexed it"

    ActiveSearch.index(:comments).remove(comment)
    refresh_comments
    assert_results [], comment_search("Original"), "control: the document is gone"

    comment.save!
    refresh_comments

    assert_results comment, comment_search("Original")
  end

  test "a touch does not reindex" do
    comment = Comment.create!(body: "Untouched", account_id: 1)
    refresh_comments
    ActiveSearch.index(:comments).remove(comment)
    refresh_comments
    assert_results [], comment_search("Untouched"), "control: the document is gone"

    comment.touch
    refresh_comments

    assert_results [], comment_search("Untouched")
  end

  test "a touch reindexes the index that asked, and only that one" do
    comment = Comment.create!(body: "Touched back", account_id: 1)
    refresh_comments
    ActiveSearch.index(:comments).remove(comment)
    ActiveSearch.index(:records).remove(comment)
    refresh_comments
    assert_results [], comment_search("Touched"), "control: the document is gone"
    assert_results [], records_search("Touched"), "control: the other document is gone too"

    asking(:comments) { comment.touch }
    refresh_comments

    assert_results comment, comment_search("Touched")
    assert_results [], records_search("Touched"), ":records never asked to be rewritten"
  end

  test "has_search carries the option to the reflection" do
    original = Comment._index_reflections
    Comment.has_search(index: :comments, **original.fetch(:comments).options.merge(reindex_on_touch: true))

    assert_predicate Comment._index_reflections.fetch(:comments), :reindex_on_touch?
    assert_not Comment._index_reflections.fetch(:records).reindex_on_touch?
  ensure
    Comment.send(:_index_reflections=, original)
  end

  test "a save in the same transaction still writes every index, in either order" do
    { save_first: "Alpha", touch_first: "Beta" }.each do |order, word|
      comment = Comment.create!(body: word, account_id: 1)
      refresh_comments
      ActiveSearch.index(:comments).remove(comment)
      ActiveSearch.index(:records).remove(comment)
      refresh_comments
      assert_results [], comment_search(word), "control: gone before #{order}"

      asking(:comments) do
        Comment.transaction do
          comment.touch unless order == :save_first
          comment.update!(body: word)
          comment.touch if order == :save_first
        end
      end
      refresh_comments

      assert_results comment, comment_search(word), order
      assert_results comment, records_search(word), "#{order}: the index that never asked"
    end
  end

  test "a touch inside suppress_indexing does not reindex, even where an index asked" do
    comment = Comment.create!(body: "Quietly asked", account_id: 1)
    refresh_comments
    ActiveSearch.index(:comments).remove(comment)
    refresh_comments

    asking(:comments) { Comment.suppress_indexing { comment.touch } }
    refresh_comments

    assert_results [], comment_search("Quietly asked")
  end

  test "a touch inside suppress_indexing does not reindex" do
    comment = Comment.create!(body: "Quietly untouched", account_id: 1)
    refresh_comments
    ActiveSearch.index(:comments).remove(comment)
    refresh_comments

    Comment.suppress_indexing { comment.touch }
    refresh_comments

    assert_results [], comment_search("Quietly")
  end

  test "suppression still skips the write" do
    comment = Comment.suppress_indexing { Comment.create!(body: "Quiet", account_id: 1) }
    refresh_comments

    assert_results [], comment_search("Quiet")
  end

  test "destroy removes the document even inside suppress_indexing" do
    comment = Comment.create!(body: "Doomed", account_id: 1)
    refresh_comments
    assert_results comment, comment_search("Doomed"), "control: the create indexed it"

    Comment.suppress_indexing { comment.destroy! }
    refresh_comments

    assert_results [], comment_search("Doomed")
  end

  test "reindex arrives only on a model that opts in" do
    assert_not Author.new.respond_to?(:reindex)
    assert_respond_to Article.new, :reindex
  end

  private
    def guarded_search
      ActiveSearch.index(:guarded_articles).search("Qualifying")
    end

    def refresh_guarded
      ActiveSearch.index(:guarded_articles).store.refresh(:guarded_articles)
    rescue StandardError
      nil
    end

    def asking(index_name)
      original = Comment._index_reflections
      options = original.fetch(index_name).options.merge(reindex_on_touch: true)
      Comment.send(:_index_reflections=,
        original.merge(index_name => ActiveSearch::IndexReflection.new(index_name, options)))
      yield
    ensure
      Comment.send(:_index_reflections=, original)
    end

    def records_search(term)
      ActiveSearch.index(:records).search(term)
    end

    def comment_search(term)
      ActiveSearch.index(:comments).search(term)
    end

    def refresh_comments
      ActiveSearch.index(:comments).store.refresh(:comments)
      ActiveSearch.index(:records).store.refresh(:records)
    rescue StandardError
      nil
    end
end
