require "test_helper"

class PolymorphicRecordIndexTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  searches :records

  def index
    ActiveSearch.index(:records)
  end

  setup do
    Post
    Page
  end

  test "index_name returns configured name" do
    assert_equal :records, index.name
  end

  test "polymorphic index stores document with GlobalID identifier" do
    post = Post.create!(headline: "Test Polymorphic ID", body: "Content", account_id: 1)
    page = Page.create!(title: "Test Polymorphic ID", content: "Content", account_id: 1)

    index.add(post)
    index.add(page)

    results = index.search("Test Polymorphic ID").results
    assert_equal 2, results.total

    classes = results.map(&:class)
    assert_includes classes, Post
    assert_includes classes, Page
  end

  test "search results include record_type and record_id in fields" do
    post = Post.create!(headline: "Test Doc Type", body: "Content", account_id: 1)
    page = Page.create!(title: "Test Doc Type", content: "Content", account_id: 1)

    index.add(post)
    index.add(page)

    results = index.search("Test Doc Type").results
    assert_equal 2, results.total

    results.each do |result|
      doc_type = Array(result.hit.fields[:record_type]).first
      record_id = Array(result.hit.fields[:record_id]).first
      assert_includes %w[Post Page], doc_type
      assert [ Integer, String ].any? { |klass| record_id.is_a?(klass) },
        "record_id should be Integer or String, got #{record_id.class}"
    end
  end

  test "record_type in search results matches canonical class name" do
    post = Post.create!(headline: "Test Canonical Name", body: "Content", account_id: 1)
    index.add(post)

    results = ActiveSearch.index(:records).search("Test Canonical Name").results
    assert_equal 1, results.total

    doc_type = Array(results.first.hit.fields[:record_type]).first
    doc_id = Array(results.first.hit.fields[:record_id]).first
    assert_equal "Post", doc_type
    assert_equal post.id.to_s, doc_id.to_s
  end

  test "index_document indexes with type filter" do
    post = Post.create!(headline: "Indexed Post", body: "Post body", account_id: 1)
    index.add(post)

    results = Post.search("Indexed Post").results
    assert_equal 1, results.total
    assert_equal post, results.first
  end

  test "search returns mixed results" do
    post = Post.create!(headline: "Mixed Search", body: "Post body", account_id: 1)
    page = Page.create!(title: "Mixed Search", content: "Page body", account_id: 1)

    index.add(post)
    index.add(page)

    results = index.search("Mixed Search").results
    assert_equal 2, results.total
    assert_includes results, post
    assert_includes results, page
  end

  test "polymorphic .search auto-scopes to model type" do
    post = Post.create!(headline: "Auto Scope Test", body: "Content", account_id: 1)
    page = Page.create!(title: "Auto Scope Test", content: "Content", account_id: 1)

    index.add(post)
    index.add(page)

    results = Post.search("Auto Scope Test").results
    assert_equal 1, results.total
    assert_equal post, results.first

    results = Page.search("Auto Scope Test").results
    assert_equal 1, results.total
    assert_equal page, results.first

    results = index.search("Auto Scope Test").results
    assert_equal 2, results.total
  end

  test "a caller cannot widen the protected model scope" do
    post = Post.create!(headline: "Protected Scope Test", body: "Content", account_id: 1)
    page = Page.create!(title: "Protected Scope Test", content: "Content", account_id: 1)

    index.add(post)
    index.add(page)

    assert_results [], Post.search("Protected Scope Test").filter(record_type: "Page")
  end

  test "protected model scoping is stored apart from caller conditions" do
    relation = Post.search("anything").filter(account_id: 1)
    context = query_context_for(relation)

    assert_equal [ :record_type ], context.protected_conditions.map(&:field)
    assert_equal [ :account_id ], context.conditions.map(&:field)
  end

  test "protected conditions reach the backend before caller conditions" do
    relation = Post.search("anything").filter(account_id: 1)

    assert_equal [ :record_type, :account_id ], query_context_for(relation).all_conditions.map(&:field)
  end

  test "polymorphic .search uses subclass name for STI/inheritance" do
    subclass = Class.new(Post) do
      def self.name; "SpecialPost"; end
    end

    relation = subclass.search("anything")
    condition = query_context_for(relation).protected_conditions.for_field(:record_type).first

    assert_equal "SpecialPost", condition.value,
      "Polymorphic type filter should use the calling subclass name, not the parent"
  end

  test "remove_document removes from index" do
    post = Post.create!(headline: "To Remove", body: "Content", account_id: 1)
    index.add(post)

    results = Post.search("To Remove").results
    assert_equal 1, results.total

    index.remove(post)

    results = Post.search("To Remove").results
    assert_equal 0, results.total
  end

  test "batch indexes multiple documents with correct types" do
    posts = 2.times.map { |i| Post.create!(headline: "Batch Post #{i}", body: "Content", account_id: 1) }
    pages = 2.times.map { |i| Page.create!(title: "Batch Page #{i}", content: "Content", account_id: 1) }

    index.batch do |batch|
      posts.each { |p| batch.add(p) }
      pages.each { |p| batch.add(p) }
    end

    results = index.search("Batch").results
    assert_equal 4, results.total

    post_results = index.search("Batch").filter(record_type: "Post").results
    assert_equal 2, post_results.total

    page_results = index.search("Batch").filter(record_type: "Page").results
    assert_equal 2, page_results.total
  end

  test "batch removes multiple documents" do
    posts = 2.times.map { |i| Post.create!(headline: "Batch Remove #{i}", body: "Content", account_id: 1).tap { |p| index.add(p) } }

    results = Post.search("Batch Remove").results
    assert_equal 2, results.total

    index.batch do |batch|
      posts.each { |p| batch.remove(p) }
    end

    results = Post.search("Batch Remove").results
    assert_equal 0, results.total
  end

  test "automatic indexing on create" do
    perform_enqueued_jobs do
      post = Post.create!(headline: "Auto Indexed", body: "Content", account_id: 1)

      results = Post.search("Auto Indexed").results
      assert_equal 1, results.total
      assert_equal post, results.first
    end
  end

  test "automatic indexing on update" do
    perform_enqueued_jobs do
      post = Post.create!(headline: "Strawberry", body: "Smoothie", account_id: 1)

      results = Post.search("Strawberry").results
      assert_equal 1, results.total

      post.update!(headline: "Blueberry")

      results = Post.search("Blueberry").results
      assert_equal 1, results.total

      results = Post.search("Strawberry").results
      assert_equal 0, results.total
    end
  end

  test "automatic removal on destroy" do
    perform_enqueued_jobs do
      post = Post.create!(headline: "To Be Destroyed", body: "Content", account_id: 1)

      results = Post.search("To Be Destroyed").results
      assert_equal 1, results.total

      post.destroy!

      results = Post.search("To Be Destroyed").results
      assert_equal 0, results.total
    end
  end

  test "different field mappings work correctly" do
    perform_enqueued_jobs do
      post = Post.create!(headline: "Post Headline", body: "Post Body Text", account_id: 1)

      page = Page.create!(title: "Page Title", content: "Page Content Text", account_id: 1)

      results = Post.search("Headline").results
      assert_equal 1, results.total
      assert_equal post, results.first

      results = Page.search("Page Title").results
      assert_equal 1, results.total
      assert_equal page, results.first
    end
  end

  test "score returns correct value for polymorphic records" do
    post = Post.create!(headline: "Score Test Post", body: "Content", account_id: 1)
    page = Page.create!(title: "Score Test Page", content: "Content", account_id: 1)

    index.add(post)
    index.add(page)

    results = index.search("Score Test").results
    assert_equal 2, results.total

    results.each do |result|
      assert result.hit.score != 0, "Score should be non-zero for result #{result.id}"
    end
  end

  test "polymorphic results maintain correct order with mixed types" do
    post1 = Post.create!(headline: "Alpha Ranking", body: "First", account_id: 1)
    page1 = Page.create!(title: "Beta Ranking", content: "Second", account_id: 1)
    post2 = Post.create!(headline: "Alpha Ranking Match", body: "Third", account_id: 1)

    index.add(post1)
    index.add(page1)
    index.add(post2)

    results = index.search("Ranking").results
    assert_equal 3, results.total

    record_ids = results.map { |r| "#{r.class.table_name}/#{r.id}" }
    assert_includes record_ids, "posts/#{post1.id}"
    assert_includes record_ids, "pages/#{page1.id}"
    assert_includes record_ids, "posts/#{post2.id}"
  end

  test "polymorphic source handles namespaced classes" do
    Admin::Document

    doc = Admin::Document.create!(title: "Namespaced Test", body: "Content", account_id: 1)
    index.add(doc)

    results = index.search("Namespaced").results
    assert_equal 1, results.total
    assert_instance_of Admin::Document, results.first
  ensure
    doc&.destroy
  end

  test "source resolves GlobalIDs to records" do
    post = Post.create!(headline: "Valid Post", body: "Content", account_id: 1)

    source = ActiveSearch::Source::Polymorphic.new(name: :record, index_name: :records)
    ids = [ post.to_global_id.to_s ]
    records = source.records_for(ids)

    assert_equal 1, records.size
    assert_equal post, records.first
  end

  test "source skips malformed GlobalIDs" do
    post = Post.create!(headline: "Valid Post", body: "Content", account_id: 1)

    source = ActiveSearch::Source::Polymorphic.new(name: :record, index_name: :records)
    ids = [ "malformed_id", post.to_global_id.to_s, "another_bad_id" ]
    records = source.records_for(ids)

    assert_equal 1, records.size
    assert_equal post, records.first
  end

  test "source skips unknown class names in GlobalID" do
    post = Post.create!(headline: "Valid Post", body: "Content", account_id: 1)

    source = ActiveSearch::Source::Polymorphic.new(name: :record, index_name: :records)
    ids = [ "gid://dummy/DeletedModel/123", post.to_global_id.to_s, "gid://dummy/NonExistentClass/456" ]
    records = source.records_for(ids)

    assert_equal 1, records.size
    assert_equal post, records.first
  end

  test "source handles empty and nil-like IDs gracefully" do
    post = Post.create!(headline: "Valid Post", body: "Content", account_id: 1)

    source = ActiveSearch::Source::Polymorphic.new(name: :record, index_name: :records)
    ids = [ "", "gid://dummy//123", post.to_global_id.to_s ]
    records = source.records_for(ids)

    assert_equal 1, records.size
    assert_equal post, records.first
  end

  test "source generates GlobalID for id_for" do
    post = Post.create!(headline: "Test Post", body: "Content", account_id: 1)

    source = ActiveSearch::Source::Polymorphic.new(name: :record, index_name: :records)
    id = source.id_for(post)

    assert_equal post.to_global_id.to_s, id
  end

  test "source identity_attributes_for returns type and id" do
    post = Post.create!(headline: "Identity Test", body: "Content", account_id: 1)

    source = ActiveSearch::Source::Polymorphic.new(name: :record, index_name: :records)
    attrs = source.identity_attributes_for(post)

    assert_equal({ record_type: "Post", record_id: post.id.to_s }, attrs)
  end

  test "each class hydrates through its own declared scope" do
    source = ActiveSearch::Source::Polymorphic.new(name: :record, index_name: :records)

    assert_equal Comment.where.not(body: nil).to_sql, source.send(:scope_for, Comment).to_sql
  end

  test "a class with no declaration for this index hydrates unscoped" do
    source = ActiveSearch::Source::Polymorphic.new(name: :record, index_name: :records)

    assert_equal Page.all.to_sql, source.send(:scope_for, Page).to_sql
  end

  test "an STI subclass evaluates an inherited declaration against itself" do
    subclass = Class.new(Post) do
      def self.name = "InheritingPost"
    end
    source = ActiveSearch::Source::Polymorphic.new(name: :record, index_name: :records)

    relation = source.send(:scope_for, subclass)

    assert_equal subclass, relation.klass, "evaluated against the subclass, not Post"
    assert_includes relation.to_sql, "headline", "and kept the inherited predicate"
  end

  test "a declaration returning nothing is a mistake rather than an absence" do
    reflection = Comment._index_reflections[:records]
    original = reflection.options[:scope]
    reflection.options[:scope] = -> { nil }
    source = ActiveSearch::Source::Polymorphic.new(name: :record, index_name: :records)

    assert_raises(ActiveSearch::QueryError) { source.send(:scope_for, Comment) }
  ensure
    reflection.options[:scope] = original
  end

  test "a declaration that does not load its own class is refused" do
    source = ActiveSearch::Source::Polymorphic.new(name: :record, index_name: :records)
    reflection = Comment._index_reflections[:records]
    original = reflection.options[:scope]
    reflection.options[:scope] = -> { Page.all }

    assert_raises(ActiveSearch::QueryError) { source.send(:scope_for, Comment) }
  ensure
    reflection.options[:scope] = original
  end

  test "source type_filter_for returns type filter" do
    source = ActiveSearch::Source::Polymorphic.new(name: :record, index_name: :records)
    scope = source.type_filter_for(Post)

    assert_equal({ record_type: "Post" }, scope)
  end

  test "source storage_key parses GlobalID into type and id" do
    post = Post.create!(headline: "Storage Key Test", body: "Content", account_id: 1)

    source = ActiveSearch::Source::Polymorphic.new(name: :record, index_name: :records)
    key = source.storage_key(post.to_global_id.to_s)

    assert_equal({ record_type: "Post", record_id: post.id.to_s }, key)
  end

  test "source build_document_id reconstructs GlobalID from stored columns" do
    source = ActiveSearch::Source::Polymorphic.new(name: :record, index_name: :records)
    gid = source.build_document_id(record_type: "Post", record_id: "42")

    assert_equal "gid://#{GlobalID.app}/Post/42", gid
  end

  test "source identity_fields lists type and id columns" do
    source = ActiveSearch::Source::Polymorphic.new(name: :record, index_name: :records)

    assert_equal [ :record_type, :record_id ], source.identity_fields
  end
end
