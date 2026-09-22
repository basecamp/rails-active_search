require "test_helper"

class EpochMicrosecondsDateTimeTypeTest < ActiveSupport::TestCase
  setup do
    @type = ActiveSearch::Type::EpochMicrosecondsDateTime.new
  end

  test "a signed integer string casts the same as the integer" do
    assert_equal @type.cast(-1), @type.cast("-1")
    assert_equal Time.at(Rational(-1, 1_000_000)).utc, @type.cast("-1")
  end

  test "an unsigned integer string casts to the microsecond timestamp" do
    assert_equal Time.at(1_700_000_000).utc, @type.cast("1700000000000000")
  end

  test "a non-numeric string is not treated as a timestamp" do
    assert_equal Time.utc(2026, 9, 16), @type.cast("2026-09-16 00:00:00 UTC")
  end

  test "serialize and cast round-trip a sub-second time exactly" do
    time = Time.utc(2026, 9, 16, 5, 6, 7, 123456)
    assert_equal time, @type.cast(@type.serialize(time))
  end
end
