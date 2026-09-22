require "test_helper"

# The harness loads the elasticsearch gem before any adapter, so the broken order can only be
# reproduced in a clean subprocess.
class ElasticLoadOrderTest < ActiveSupport::TestCase
  REPO_ROOT = File.expand_path("../..", __dir__)

  test "elasticsearch client errors survive the opensearch adapter loading first" do
    script = <<~RUBY
      require "bundler/setup"
      require "rails"
      require "active_search"
      abort "premise failed: the elasticsearch gem is already loaded" if defined?(::Elasticsearch)
      ActiveSearch::StoreAdapters::Opensearch
      errors = ActiveSearch::StoreAdapters::Elasticsearch::CLIENT_ERRORS
      abort "CLIENT_ERRORS is empty: transport failures would pass through untranslated" if errors.empty?
      puts "client_errors:" + errors.size.to_s
    RUBY

    output = IO.popen([ RbConfig.ruby, "-e", script ], chdir: REPO_ROOT, err: [ :child, :out ], &:read)

    assert_predicate $?, :success?, output
    assert_match(/client_errors:[12]/, output)
  end

  test "the elasticsearch version gate compares numerically not lexicographically" do
    elastic = ActiveSearch::StoreAdapters::Elastic

    assert elastic.legacy_elasticsearch?("7.17.9")
    assert_not elastic.legacy_elasticsearch?("8.0.0")
    assert_not elastic.legacy_elasticsearch?("10.3.0")
    assert_not elastic.legacy_elasticsearch?(nil)
  end
end
