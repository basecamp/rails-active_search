require "test_helper"

class WriteContractTest < ActiveSupport::TestCase
  searches :articles

  def add(article)
    ActiveSearch.index(:articles).add(article)
  end

  def search
    ActiveSearch.index(:articles).search("Shared")
  end

  test "a replacement that omits a field clears the old value" do
    article = Article.create!(title: "Renamed", content: "Shared", account_id: 1, status: "published")
    add(article)

    assert_results article, search.filter(status: "published"),
      "control: the first write is findable by its status"

    article.update!(status: nil)
    add(article)

    assert_results [], search.filter(status: "published"),
      "the omitted field must not survive the replacement"
    assert_results article, search,
      "control: the document itself is still indexed"
  end

  test "a batched replacement clears the old value too" do
    article = Article.create!(title: "Batched", content: "Shared", account_id: 1, status: "published")
    ActiveSearch.index(:articles).batch { |batch| batch.add(article) }

    assert_results article, search.filter(status: "published"),
      "control: the batched write is findable by its status"

    article.update!(status: nil)
    ActiveSearch.index(:articles).batch { |batch| batch.add(article) }

    assert_results [], search.filter(status: "published"),
      "the omitted field must not survive a batched replacement"
    assert_results article, search,
      "control: the document itself is still indexed"
  end

  test "a replacement that changes a field does not leave the old value behind" do
    article = Article.create!(title: "Changed", content: "Shared", account_id: 1, status: "published")
    add(article)

    article.update!(status: "archived")
    add(article)

    assert_results [], search.filter(status: "published")
    assert_results article, search.filter(status: "archived")
  end

  test "a blank string is a present value and survives" do
    article = Article.create!(title: "Blank", content: "Shared", account_id: 1, status: "")
    add(article)

    skip "adapter has no missing filters" unless capabilities.supports_missing_filters?

    skip "Solr cannot distinguish a blank string from an absent field" if store_adapter_name == :solr

    assert_results article, search.reject(status: nil),
      "a blank string is present, so it must not read as absent"
  end

  test "false is a present value and survives" do
    article = Article.create!(title: "Flag", content: "Shared", account_id: 1, status: "published", featured: false)
    add(article)

    assert_results article, search.filter(featured: false)

    skip "adapter has no missing filters" unless capabilities.supports_missing_filters?

    assert_results article, search.reject(featured: nil),
      "false is present, so it must not read as absent"
  end

  test "zero is a present value and survives" do
    article = Article.create!(title: "Zero", content: "Shared", account_id: 0, status: "published")
    add(article)

    assert_results article, search.filter(account_id: 0)

    skip "adapter has no missing filters" unless capabilities.supports_missing_filters?

    assert_results article, search.reject(account_id: nil),
      "zero is present, so it must not read as absent"
  end

  test "a field supplied as nil reads as absent" do
    skip "adapter has no missing filters" unless capabilities.supports_missing_filters?

    article = Article.create!(title: "Nil", content: "Shared", account_id: 1, status: nil)
    add(article)

    assert_results article, search.filter(status: nil)
  end

  test "Document treats a nil field as absent and keeps blank, false, and zero" do
    definition = ActiveSearch.index(:articles).definition
    document = ActiveSearch::Document.new(
      id: "gid://dummy/Article/1",
      data: { title: "", content: nil, account_id: 0, featured: false },
      definition: definition
    )

    assert_equal "", document.data[:title]
    assert_equal 0, document.data[:account_id]
    assert_equal false, document.data[:featured]
    assert_not document.data.key?(:content), "a nil field must be absent, not present-and-nil"

    assert_includes document.absent_fields, :content
    assert_includes document.absent_fields, :status
    assert_not_includes document.absent_fields, :title
    assert_not_includes document.absent_fields, :featured
  end

  test "absent_fields is scoped to declared fields" do
    definition = ActiveSearch.index(:articles).definition
    document = ActiveSearch::Document.new(id: "gid://dummy/Article/1", data: {}, definition: definition)

    assert_equal definition.field_names.sort, document.absent_fields.sort
    assert_not_includes document.absent_fields, :id
    assert_not_includes document.absent_fields, :rowid
  end

  test "the last batch operation for an id wins" do
    article = Article.create!(title: "BatchOrder", content: "text", account_id: 1)
    index = ActiveSearch.index(:articles)

    index.batch do |batch|
      batch.remove(article)
      batch.add(article)
    end
    refresh_articles
    assert_results [ article ], index.search("BatchOrder"),
      "remove-then-add of one id must end present"

    index.batch do |batch|
      batch.add(article)
      batch.remove(article)
    end
    refresh_articles
    assert_results [], index.search("BatchOrder"),
      "add-then-remove of one id must end absent"
  end

  class RecordingMeilisearch < ActiveSearch::StoreAdapters::Meilisearch
    class Recorder
      attr_reader :calls
      def initialize = @calls = []

      def add_documents(docs)
        @calls << :add_documents
        { "taskUid" => 1 }
      end

      def delete_documents(ids)
        @calls << :delete_documents
        { "taskUid" => 2 }
      end
    end

    def recorder = @recorder ||= Recorder.new

    private
      def index_for(_index_name) = recorder
      def await(task, allow: []) = task
  end

  class RecordingSolr < ActiveSearch::StoreAdapters::Solr
    class Recorder
      attr_reader :calls
      def initialize = @calls = []

      def add(docs, params: nil)
        @calls << :add
      end

      def delete_by_id(ids, params: nil)
        @calls << :delete_by_id
      end
    end

    def recorder = @recorder ||= Recorder.new
    def client(_index_name) = recorder

    private
      def soft_commit(_index_name) = nil
  end

  def probe_document
    ActiveSearch::Document.new(id: "1", definition: ActiveSearch.index(:articles).definition,
      data: { title: "probe" })
  end

  test "meilisearch flush sends a same-id remove before the add that follows it" do
    adapter = RecordingMeilisearch.new
    operations = [ [ :remove, [ "1", nil ] ], [ :add, [ probe_document, nil ] ] ]

    adapter.send(:flush, ActiveSearch.index(:articles), operations)

    assert_equal [ :delete_documents, :add_documents ], adapter.recorder.calls,
      "adds are sent before deletes, so remove-then-add of one id ends deleted"
  end

  test "solr flush sends a same-id add before the remove that follows it" do
    adapter = RecordingSolr.new
    operations = [ [ :add, [ probe_document, nil ] ], [ :remove, [ "1", nil ] ] ]

    adapter.send(:flush, ActiveSearch.index(:articles), operations)

    assert_equal [ :add, :delete_by_id ], adapter.recorder.calls,
      "deletes are sent before adds, so add-then-remove of one id leaves a ghost document"
  end

  private
    def refresh_articles
      ActiveSearch.index(:articles).store.refresh(:articles)
    rescue StandardError
      nil
    end
end
