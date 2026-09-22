require "test_helper"

class ErrorContractTest < ActiveSupport::TestCase
  searches :articles

  test "Error inherits from StandardError" do
    assert_equal StandardError, ActiveSearch::Error.superclass
  end

  test "QueryError inherits from Error" do
    assert_equal ActiveSearch::Error, ActiveSearch::QueryError.superclass
  end

  test "DocumentError inherits from Error" do
    assert_equal ActiveSearch::Error, ActiveSearch::DocumentError.superclass
  end

  test "ConfigurationError inherits from Error" do
    assert_equal ActiveSearch::Error, ActiveSearch::ConfigurationError.superclass
  end

  test "AdapterError inherits from Error" do
    assert_equal ActiveSearch::Error, ActiveSearch::AdapterError.superclass
  end

  test "UnsupportedOperationError inherits from QueryError" do
    assert_equal ActiveSearch::QueryError, ActiveSearch::UnsupportedOperationError.superclass
  end

  test "every public error is rescuable as ActiveSearch::Error" do
    [
      ActiveSearch::QueryError,
      ActiveSearch::DocumentError,
      ActiveSearch::ConfigurationError,
      ActiveSearch::AdapterError,
      ActiveSearch::UnsupportedOperationError
    ].each do |error_class|
      assert_operator error_class, :<, ActiveSearch::Error
    end
  end

  test "an unsupported operation is rescuable as a query error" do
    assert_raises(ActiveSearch::QueryError) do
      raise ActiveSearch::UnsupportedOperationError, "unsupported"
    end
  end

  def store
    ActiveSearch.index(:articles).store
  end

  class Boom < StandardError; end

  test "every adapter declares a frozen CLIENT_ERRORS array" do
    assert_kind_of Array, store.class::CLIENT_ERRORS
    assert_predicate store.class::CLIENT_ERRORS, :frozen?
    assert_not_empty store.class::CLIENT_ERRORS,
      "#{store.class.name} should declare the backend exceptions it handles"
  end

  test "every declared client error is a raisable exception class" do
    store.class::CLIENT_ERRORS.each do |declared|
      assert_kind_of Class, declared,
        "#{declared} is not a Class, so rescuing it would depend on it being an ancestor"
      assert_operator declared, :<=, StandardError,
        "#{declared} does not descend from StandardError, so it cannot be raised as a backend failure"
    end
  end

  def translating(store, &block)
    store.send(:translating_errors, &block)
  end

  test "a declared backend failure is wrapped as AdapterError with the original as cause" do
    declared = store.class::CLIENT_ERRORS.first
    original = build_client_error(declared)

    error = assert_raises(ActiveSearch::AdapterError) do
      translating(store) { raise original }
    end

    assert_same original, error.cause, "the original exception must be preserved as cause"
    assert_match(/request failed/, error.message)
    assert_match(/#{Regexp.escape(declared.name)}/, error.message)
  end

  test "a client error whose message raises is still wrapped" do
    declared = store.class::CLIENT_ERRORS.first
    hostile = declared.allocate

    def hostile.message
      raise NoMethodError, "undefined method '[]' for nil"
    end

    assert_raises(ActiveSearch::AdapterError) { translating(store) { raise hostile } }
  end

  test "an undeclared exception passes through unchanged" do
    assert_raises(Boom) { translating(store) { raise Boom, "not a backend failure" } }
  end

  test "an ActiveSearch error is never wrapped" do
    assert_raises(ActiveSearch::QueryError) { translating(store) { raise ActiveSearch::QueryError, "bad query" } }
    assert_raises(ActiveSearch::DocumentError) { translating(store) { raise ActiveSearch::DocumentError, "bad doc" } }
  end

  test "an adapter that declares no client errors wraps nothing" do
    bare = Class.new(ActiveSearch::StoreAdapters::Base).new

    assert_raises(Boom) { translating(bare) { raise Boom } }
  end

  test "AdapterError is rescuable as ActiveSearch::Error" do
    declared = store.class::CLIENT_ERRORS.first

    assert_raises(ActiveSearch::Error) { translating(store) { raise build_client_error(declared) } }
  end

  test "an exception raised inside a native block is not wrapped" do
    relation = ActiveSearch.index(:articles).search("anything").native { |_q| raise Boom, "from the block" }

    assert_raises(Boom) { relation.results }
    assert_raises(Boom) { relation.to_native_query }
  end

  test "UnsupportedOperation is removed" do
    assert_not ActiveSearch.const_defined?(:UnsupportedOperation, false),
      "ActiveSearch::UnsupportedOperation was replaced by UnsupportedOperationError"
  end

  private
    def build_client_error(klass)
      klass.new("backend said no")
    rescue ArgumentError, TypeError
      klass.allocate
    end

  test "every operation reaches a caller as AdapterError, not as a client exception" do
    declared = store.class::CLIENT_ERRORS.first
    skip "adapter declares no client errors" unless declared

    failing = failing_store(declared)
    index = ActiveSearch.index(:articles)
    document = index.document_for(Article.create!(title: "Boundary", content: "c", account_id: 1))

    assert_raises(ActiveSearch::AdapterError) { failing.add(index, document) }
    assert_raises(ActiveSearch::AdapterError) { failing.remove(index, document.id) }
    assert_raises(ActiveSearch::AdapterError) { failing.flush_batch(index, [ [ :add, [ document, nil ] ] ]) }
  end

  def failing_store(declared)
    error = build_client_error(declared)

    store.class.new(**store.options).tap do |failing|
      failing.define_singleton_method(:write) { |*, **| raise error }
      failing.define_singleton_method(:delete) { |*, **| raise error }
      failing.define_singleton_method(:flush) { |*, **| raise error }
    end
  end
end
