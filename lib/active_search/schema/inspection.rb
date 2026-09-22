module ActiveSearch
  module Schema # :nodoc: all
    # What a store reports about an index. One state rather than exists-plus-a-reason, so a store
    # that did not answer cannot read as an index that is not there.
    Inspection = Data.define(:state, :observed, :detail) do
      STATES = %i[ found missing unavailable ].freeze

      def initialize(state:, observed: [], detail: nil)
        unless STATES.include?(state)
          raise ArgumentError, "Unknown inspection state #{state.inspect}. Valid: #{STATES.join(", ")}."
        end

        super(state: state, observed: observed.freeze, detail: detail)
      end

      def found?
        state == :found
      end

      def missing?
        state == :missing
      end

      def unavailable?
        state == :unavailable
      end

      def observations_for(name)
        observed.select { |observation| observation.name == name.to_s }
      end

      # A name is not unique: SQLite keeps a document's text in an FTS5 table and its filterable
      # values in another, and a column can appear in both.
      def satisfying(requirement)
        observations_for(requirement.name).find do |observation|
          agrees?(observation.location, requirement.location) &&
            agrees?(observation.role, requirement.role) &&
            agrees?(observation.native_type, requirement.native_type)
        end
      end

      private
        # Asymmetric. A nil requirement is not checked. A nil observation satisfies nothing: a
        # column type nothing recognises must not prove an integer. An Array lists what is accepted.
        def agrees?(observed_value, required_value)
          case required_value
          when nil then true
          when Array then required_value.include?(observed_value)
          else observed_value == required_value
          end
        end
    end
  end
end
