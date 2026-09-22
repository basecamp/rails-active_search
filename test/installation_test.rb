require "test_helper"

class InstallationTest < ActiveSupport::TestCase
  def build_model(name, &block)
    Class.new(ApplicationRecord) do
      self.table_name = "articles"
      define_singleton_method(:name) { name }
      class_eval(&block) if block
    end
  end

  test "refuses to install over a conflicting class method" do
    %i[search suppress_indexing indexing_suppressed?].each do |method|
      klass = build_model("Conflicting#{method.to_s.delete("?").camelize}") do
        define_singleton_method(method) { :mine }
      end

      error = assert_raises(ActiveSearch::ConfigurationError, "expected #{method} to be refused") do
        klass.has_search index: :articles
      end

      assert_match(/class method #{Regexp.escape(method.to_s)} on .* is defined by/, error.message)
    end
  end

  test "refuses to install over a conflicting instance method" do
    klass = build_model("ConflictingHit") { def hit; :mine; end }

    error = assert_raises(ActiveSearch::ConfigurationError) { klass.has_search index: :articles }

    assert_match(/instance method hit on .* is defined by/, error.message)
  end

  module OwnSearch
    def search(*)
      :mine
    end
  end

  test "the refusal names the offending owner and what to do" do
    klass = build_model("NamedConflict") { extend OwnSearch }

    error = assert_raises(ActiveSearch::ConfigurationError) { klass.has_search index: :articles }

    assert_match(/is defined by InstallationTest::OwnSearch/, error.message,
      "a consumer needs to know which of its own modules is in the way")
    assert_match(/Rename yours/, error.message)
    assert_match(/delegate to ActiveSearch's/, error.message)
  end

  module OwnHitWriter
    def hit=(value)
      @mine = value
    end
  end

  module OwnReindex
    def reindex
      :mine
    end
  end

  test "a consumer's own reindex is refused rather than shadowed" do
    klass = build_model("ReindexConflict") { include OwnReindex }

    error = assert_raises(ActiveSearch::ConfigurationError) { klass.has_search index: :articles }

    assert_match(/instance method reindex on .* is defined by/, error.message)
    assert_match(/is defined by InstallationTest::OwnReindex/, error.message)
  end

  test "every method the gem installs is refused, including the ones a list would forget" do
    installed = ActiveSearch::Model::ClassMethods.instance_methods +
      ActiveSearch::Model.public_instance_methods

    assert_includes installed, :reindex, "a method added to Model joins the refusal list by derivation"
    assert_includes installed, :hit=

    klass = build_model("HitWriterConflict") { include OwnHitWriter }
    error = assert_raises(ActiveSearch::ConfigurationError) { klass.has_search index: :articles }

    assert_match(/instance method hit= on .* is defined by/, error.message)
    assert_match(/is defined by InstallationTest::OwnHitWriter/, error.message)
  end

  test "a consumer module whose name starts with ActiveSearch is still a conflict" do
    prefixed = Module.new do
      def self.name
        "ActiveSearchExtras::Searching"
      end

      def search(*)
        :mine
      end
    end

    klass = build_model("PrefixConflict") { extend prefixed }

    assert_raises(ActiveSearch::ConfigurationError) { klass.has_search index: :articles }
  end

  test "a model with no conflict installs" do
    klass = build_model("CleanInstall")

    assert_nothing_raised { klass.has_search index: :articles }
    assert_respond_to klass, :search
  end

  test "ActiveSearch does not conflict with its own installation" do
    klass = build_model("ReinstalledModel")

    klass.has_search index: :articles
    assert_nothing_raised { klass.has_search index: :comments }

    assert_equal [ :articles, :comments ], klass._index_reflections.keys
  end

  test "reinstalling does not duplicate the lifecycle callbacks" do
    klass = build_model("CallbackCount")

    klass.has_search index: :articles
    before = klass._save_callbacks.count { |c| c.filter == ActiveSearch::IndexingCallbacks }

    klass.has_search index: :comments
    after = klass._save_callbacks.count { |c| c.filter == ActiveSearch::IndexingCallbacks }

    assert_equal before, after, "a second has_search must not add another callback"
    assert_equal 1, after
  end

  test "suppression is scoped to one model" do
    Article.suppress_indexing do
      assert Article.indexing_suppressed?
      assert_not Comment.indexing_suppressed?, "suppressing one model must not suppress another"
    end
  end

  test "suppression is restored even when the block raises" do
    assert_not Article.indexing_suppressed?

    assert_raises(RuntimeError) do
      Article.suppress_indexing { raise "boom" }
    end

    assert_not Article.indexing_suppressed?, "the ensure must restore the previous value"
  end

  test "suppression follows the configured isolation level" do
    assert_equal :thread, ActiveSupport::IsolatedExecutionState.isolation_level,
      "this test describes the default; if an app sets :fiber, suppression follows that"

    Article.suppress_indexing do
      assert Article.indexing_suppressed?
      assert Fiber.new { Article.indexing_suppressed? }.resume,
        "at :thread level a fiber shares the state"
      assert_not Thread.new { Article.indexing_suppressed? }.value,
        "a new thread does not inherit it"
    end
  end

  test "suppression state is no longer a thread attribute" do
    assert_not Article.respond_to?(:_indexing_suppressed),
      "the thread_mattr_accessor was replaced by IsolatedExecutionState"
  end

  test "an application concern named Searchable or Indexed still wins in a model body" do
    %i[Searchable Indexed].each do |name|
      Object.const_set(name, Module.new)

      begin
        assert_equal Object.const_get(name), Article.class_eval(name.to_s),
          "#{name} in a model class body resolved to the gem's module, not the application's"
      ensure
        Object.send(:remove_const, name)
      end
    end
  end

  test "neither module defines a constant that could shadow an application's" do
    assert_equal [ :ClassMethods ], ActiveSearch::Indexable.constants.sort
    assert_equal [ :ClassMethods ], ActiveSearch::Model.constants.sort
  end

  test "a model's reflections cannot be rewritten from outside" do
    assert_raises(NoMethodError) { Article._index_reflections = {} }
    assert_raises(NoMethodError) { Article._default_search_index = :other }

    assert_equal %i[articles namespaced_tests], Article._index_reflections.keys,
      "the reader stays callable, because class_attribute's instance reader is built on it"
  end
end
