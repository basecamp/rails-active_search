require "test_helper"

class VerificationMessageTest < ActiveSupport::TestCase
  Schema = ActiveSearch::Schema

  def requirement(name, native_type)
    Schema::Requirement.new(field: name.to_sym, role: :filterable, name: name, location: nil, native_type: native_type)
  end

  def verify(observed, requirements)
    Schema::Verification.of("idx", requirements, Schema::Inspection.new(state: :found, observed: observed))
  end

  test "an absent field reads not found; a mistyped one reads present but not as declared" do
    observed = [ Schema::Observation.new(name: "created_at", role: :filterable, native_type: "date", location: nil) ]
    result = verify(observed, [ requirement("created_at", "long"), requirement("ghost", "long") ])

    assert_equal :incompatible, result.outcome
    assert_includes result.describe, "created_at (filterable, long) present but not as declared"
    assert_includes result.describe, "ghost (filterable, long) not found"
  end

  test "all-mistyped names none as not found" do
    observed = %w[ account_id board_id ].map { |n| Schema::Observation.new(name: n, role: :filterable, native_type: "uuid", location: nil) }
    result = verify(observed, [ requirement("account_id", "string"), requirement("board_id", "string") ])

    assert_includes result.describe, "present but not as declared"
    assert_not_includes result.describe, "not found"
  end
end
