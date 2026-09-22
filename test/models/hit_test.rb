require "test_helper"

class HitTest < ActiveSupport::TestCase
  test "nil fields is rejected by name at construction" do
    error = assert_raises(ArgumentError) { ActiveSearch::Hit.new(fields: nil) }
    assert_match(/fields must be a Hash, got nil/, error.message)
  end

  test "nil highlights is rejected by name at construction" do
    error = assert_raises(ArgumentError) { ActiveSearch::Hit.new(highlights: nil) }
    assert_match(/highlights must be a Hash, got nil/, error.message)
  end

  test "a non-hash fields value is rejected the same as nil" do
    error = assert_raises(ArgumentError) { ActiveSearch::Hit.new(fields: [ [ :title, "x" ] ]) }
    assert_match(/fields must be a Hash/, error.message)
  end

  test "the defaults still build an empty hit" do
    hit = ActiveSearch::Hit.new

    assert_equal({}, hit.fields)
    assert_equal({}, hit.highlights)
  end
end
