module ActiveSearch
  module Schema # :nodoc: all
    # One thing a live index must provide. Not a description of how to build it: several structures
    # satisfy the same requirement, which is why a hand-written mapping passes.
    Requirement = Data.define(:field, :role, :name, :location, :native_type) do
      def initialize(field:, role:, name:, location: nil, native_type: nil)
        super(field: field, role: role, name: name.to_s, location: location,
          native_type: native_type)
      end

      def searchable?
        role == :searchable
      end

      def describe
        wanted = native_type.is_a?(Array) ? "one of #{native_type.join(" ")}" : native_type
        detail = [ role, wanted, location && "in #{location}" ].compact.join(", ")
        "#{name} (#{detail})"
      end
    end
  end
end
