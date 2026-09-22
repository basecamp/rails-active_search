require "test_helper"

class ThreadSafetyTest < ActiveSupport::TestCase
  test "concurrent store_for returns same instance" do
    config = ActiveSearch::Configuration.new
    config.apply_store_config(adapter: :sqlite)

    results = Array.new(10)
    threads = 10.times.map { |i|
      Thread.new { results[i] = config.store_for(:default) }
    }
    threads.each(&:join)

    assert results.all? { |r| r.equal?(results[0]) },
      "All threads should receive the same store instance"
  end

  test "concurrent index resolution returns same instance" do
    results = Array.new(10)
    threads = 10.times.map { |i|
      Thread.new { results[i] = ActiveSearch.index(:articles) }
    }
    threads.each(&:join)

    assert results.all? { |r| r.equal?(results[0]) },
      "All threads should receive the same index instance"
  end
end
