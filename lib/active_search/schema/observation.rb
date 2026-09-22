module ActiveSearch
  module Schema # :nodoc: all
    # One field a store says it holds. role is nil where the store does not distinguish.
    Observation = Data.define(:name, :role, :native_type, :location) do
      def initialize(name:, role: nil, native_type: nil, location: nil)
        super(name: name.to_s, role: role, native_type: native_type,
          location: location)
      end
    end
  end
end
