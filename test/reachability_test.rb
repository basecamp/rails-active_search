require "test_helper"

class ReachabilityTest < ActiveSupport::TestCase
  UNNAMED_BY_PATH = %w[ active_search/errors active_search/version rails-active_search ].freeze

  UNAUTOLOADED = "generators/"

  test "every file in lib defines the constant its path names" do
    unreachable = ruby_files.reject do |path|
      relative = relative_to_lib(path).delete_suffix(".rb")
      relative.start_with?(UNAUTOLOADED) || UNNAMED_BY_PATH.include?(relative) ||
        relative.camelize.safe_constantize
    end

    assert_operator ruby_files.size, :>, 50, "premise: the glob found the gem"
    assert_empty unreachable.map { |path| relative_to_lib(path) },
      "nothing autoloads these, so no test can reach them"
  end

  # Bundler requires the gem by its dashed name, so the shim is the boot path.
  test "requiring the dashed gem name loads the library" do
    require "rails-active_search"
    assert defined?(ActiveSearch::VERSION)
  end

  test "eager loading the gem raises nothing" do
    assert_nothing_raised { ActiveSearch.eager_load! }
  end

  NOT_DELEGATED = {
    index: "an index does not have an index",
    definition: "Index has its own",
    source: "Index has its own",
    store: "Index has its own",
    protect: "framework-owned constraints, :nodoc:",
    with_source: ":nodoc:"
  }.freeze

  test "every Query method is delegated to an Index or listed with a reason" do
    assert_equal query_surface.sort, (delegated_methods + NOT_DELEGATED.keys).sort,
      "a Query method is neither delegated nor listed here, or a listed one no longer exists"
  end

  test "a delegated call reaches the index's own relation" do
    %i[ articles comments ].each do |name|
      index = ActiveSearch.index(name)

      assert_equal name, index.all.index.name, "premise: #{name} is its own relation"
      assert_equal name, index.filter(account_id: 1).index.name
      assert_equal index.all.to_native_query, index.to_native_query
    end
  end

  private
    def delegated_methods
      ActiveSearch::Index.instance_methods.select do |name|
        ActiveSearch::Index.instance_method(name).owner == ActiveSearch::Index::Querying
      end - [ :all ]
    end

    def query_surface
      owners = ActiveSearch::Query.ancestors.take_while { |a| a != Object } - Object.ancestors

      ActiveSearch::Query.public_instance_methods.select do |name|
        owners.include?(ActiveSearch::Query.instance_method(name).owner)
      end
    end

    def ruby_files
      @ruby_files ||= Dir.glob("#{lib_root}/**/*.rb")
    end

    def relative_to_lib(path)
      path.delete_prefix("#{lib_root}/")
    end

    def lib_root
      @lib_root ||= File.expand_path("../lib", __dir__)
    end
end
