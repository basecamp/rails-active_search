require "test_helper"

class FieldTypesTest < ActiveSupport::TestCase
  searches :articles

  def field(name, type, **options)
    ActiveSearch::Index::Field.new(name, type, **options)
  end

  def canonical(field, value, boundary: false)
    (boundary ? field.boundary_caster : field.caster).cast(value)
  end

  test "an integer field is 64-bit" do
    wide = field(:account_id, :integer)

    assert_equal 3_000_000_000, canonical(wide, 3_000_000_000)
    assert_equal 9_223_372_036_854_775_807, canonical(wide, 9_223_372_036_854_775_807)
  end

  test "a value beyond 64 bits reuses Active Model's range message" do
    error = assert_raises(ActiveSearch::Type::Invalid) { canonical(field(:account_id, :integer), 2**64) }

    assert_match(/out of range for ActiveSearch::Type::Integer with limit 8/, error.message)
  end

  test "a collection is refused rather than stringified" do
    %i[text string integer float boolean date datetime].each do |type|
      [ [ 1, 2, 3 ], { a: 1 } ].each do |collection|
        error = assert_raises(ActiveSearch::Type::Invalid, "#{collection.inspect} on a #{type} field") do
          canonical(field(:title, type), collection)
        end
        assert_match(/must be a single value/, error.message)
      end
    end
  end

  test "float keeps the value the caster produced" do
    assert_equal 0.1, canonical(field(:price, :float), 0.1)
    assert_equal 1e39, canonical(field(:price, :float), 1e39)
  end

  test "float rejects infinity and NaN" do
    assert_raises(ActiveSearch::Type::Invalid) { canonical(field(:price, :float), Float::INFINITY) }
    assert_raises(ActiveSearch::Type::Invalid) { canonical(field(:price, :float), Float::NAN) }
  end

  test "a string field still coerces what Active Model coerces" do
    assert_equal "42", canonical(field(:status, :string), 42)
    assert_equal "42", canonical(field(:title, :text), 42)
    assert_equal "1786924800", canonical(field(:starts_at, :string), 1_786_924_800)
    assert_equal "t", canonical(field(:status, :string), true)
    assert_equal "1.5", canonical(field(:status, :string), 1.5)
  end

  test "text and string require valid UTF-8 and are frozen" do
    value = canonical(field(:title, :text), "café")

    assert_equal "café", value
    assert_equal Encoding::UTF_8, value.encoding
    assert_predicate value, :frozen?
  end

  test "an invalid byte sequence is rejected rather than replaced" do
    invalid = (+"bad \xFF byte").force_encoding(Encoding::UTF_8)

    error = assert_raises(ActiveSearch::Type::Invalid) { canonical(field(:title, :text), invalid) }
    assert_match(/not valid UTF-8/, error.message)
  end

  test "an undefined conversion is rejected rather than replaced" do
    undefined = (+"\x81\x40").force_encoding(Encoding::Shift_JIS)

    assert_nothing_raised { canonical(field(:title, :text), undefined) }

    unconvertible = (+"\xFF\xFF").force_encoding(Encoding::Shift_JIS)
    assert_raises(ActiveSearch::Type::Invalid) { canonical(field(:title, :text), unconvertible) }
  end

  test "a range boundary truncates to whole seconds" do
    precise = Time.utc(2024, 1, 1, 12, 30, 45, 123_456)
    value = canonical(field(:published_at, :datetime), precise, boundary: true)

    assert_equal 0, value.usec
    assert_equal Time.utc(2024, 1, 1, 12, 30, 45), value
  end

  test "a stored datetime keeps sub-second precision" do
    precise = Time.utc(2024, 1, 1, 12, 30, 45, 123_456)
    value = canonical(field(:published_at, :datetime), precise)

    assert_equal 123_456, value.usec,
      "truncating a stored datetime would destroy the ordering key a paginated sort needs"
  end

  test "a datetime is converted to UTC" do
    zoned = ActiveSupport::TimeWithZone.new(Time.utc(2024, 1, 1, 12, 0, 0), ActiveSupport::TimeZone["Tokyo"])
    value = canonical(field(:published_at, :datetime), zoned)

    assert_predicate value, :utc?
    assert_equal Time.utc(2024, 1, 1, 12, 0, 0), value
  end

  test "boolean is left to the caster" do
    assert_equal true, canonical(field(:featured, :boolean), "1")
    assert_equal false, canonical(field(:featured, :boolean), "0")

    [ "yes", 7, Object.new, :sym ].each do |value|
      assert_includes [ true, false ], canonical(field(:featured, :boolean), value),
        "#{value.inspect} reached canonicalization as something other than a boolean"
    end
  end

  test "date canonicalizes to a Date" do
    value = canonical(field(:published_on, :date), "2024-01-01")

    assert_instance_of Date, value
    assert_equal Date.new(2024, 1, 1), value
  end

  test "date rejects what the caster passes through" do
    [ 7, Object.new ].each do |value|
      error = assert_raises(ActiveSearch::Type::Invalid, "#{value.inspect} was accepted") do
        canonical(field(:published_on, :date), value)
      end
      assert_match(/must be a Date/, error.message)
    end

    assert_instance_of Date, canonical(field(:published_on, :date), DateTime.new(2024, 1, 1))
  end

  test "a value that casts to nil is rejected" do
    assert_raises(ActiveSearch::Type::Invalid) { canonical(field(:published_at, :datetime), "not a date") }
    assert_raises(ActiveSearch::Type::Invalid) { canonical(field(:published_on, :date), "nope") }
  end

  test "a filter failure raises QueryError" do
    error = assert_raises(ActiveSearch::QueryError) { ActiveSearch.index(:articles).filter(published_at: "not a date") }
    assert_match(/published_at/, error.message)
  end

  test "a document failure raises DocumentError" do
    error = assert_raises(ActiveSearch::DocumentError) do
      ActiveSearch::Document.new(
        id: "gid://dummy/Article/1",
        data: { published_at: "not a date" },
        definition: ActiveSearch.index(:articles).definition
      )
    end

    assert_match(/published_at/, error.message)
  end

  test "an unknown document field raises DocumentError rather than ArgumentError" do
    assert_raises(ActiveSearch::DocumentError) do
      ActiveSearch::Document.new(
        id: "gid://dummy/Article/1",
        data: { nonexistent: "x" },
        definition: ActiveSearch.index(:articles).definition
      )
    end
  end

  test "a filter value and a stored value share the casting path" do
    relation = ActiveSearch.index(:articles).filter(account_id: "42")

    assert_equal 42, query_context_for(relation).all_conditions.for_field(:account_id).first.value
  end
end
