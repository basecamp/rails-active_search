module ActiveSearch
  module Schema # :nodoc: all
    # Whether a live index provides what the declaration needs. Requirements against observations,
    # never structure against structure.
    class Verification
      # Ordered by severity, which is how a run over several indexes picks its exit code.
      OUTCOMES = %i[ compatible unsupported unavailable missing incompatible error ].freeze

      EXIT_CODES = { compatible: 0, incompatible: 1, missing: 2, unavailable: 3, unsupported: 4,
                     error: 5 }.freeze

      attr_reader :index_name, :outcome, :unmet, :detail

      def self.of(index_name, requirements, inspection)
        if inspection.unavailable?
          unavailable(index_name, inspection.detail)
        elsif inspection.found?
          unmet = requirements.reject { |requirement| inspection.satisfying(requirement) }
          # A field held under the same name but a different role or type is mistyped, not absent,
          # and writes still send it because the intersection is by name.
          mismatched = unmet.select { |requirement| inspection.observations_for(requirement.name).any? }

          new(index_name, unmet.empty? ? :compatible : :incompatible, unmet, mismatched: mismatched)
        else
          missing(index_name, nil, requirements)
        end
      end

      def self.missing(index_name, reason = nil, unmet = [])
        new(index_name, :missing, unmet, reason)
      end

      def self.unavailable(index_name, reason)
        new(index_name, :unavailable, [], reason)
      end

      # Something went wrong asking, kept apart from a store that cannot answer so an adapter bug
      # does not read as a limit of the engine behind it.
      def self.error(index_name, reason)
        new(index_name, :error, [], reason)
      end

      def self.unsupported(index_name, reason)
        new(index_name, :unsupported, [], reason)
      end

      def initialize(index_name, outcome, unmet = [], detail = nil, mismatched: [])
        @index_name = index_name
        @outcome = outcome
        @unmet = unmet.freeze
        @detail = detail
        @mismatched = mismatched.freeze
      end

      def compatible?
        outcome == :compatible
      end

      def exit_code
        EXIT_CODES.fetch(outcome)
      end

      def severity
        OUTCOMES.index(outcome)
      end

      def describe
        case outcome
        when :compatible then "compatible"
        when :incompatible then "incompatible: #{incompatibility}"
        when :missing then detail ? "missing: #{detail}" : "missing"
        when :unavailable then "unavailable: #{detail}"
        when :unsupported then "unsupported: #{detail}"
        when :error then "error: #{detail}"
        end
      end

      private
        # Absent fields read "not found"; a field present under the same name but a different role
        # or type reads "present but not as declared", so a reader does not take it for dropped.
        def incompatibility
          absent = @unmet - @mismatched
          [ ("#{absent.map(&:describe).join(", ")} not found" if absent.any?),
            ("#{@mismatched.map(&:describe).join(", ")} present but not as declared" if @mismatched.any?) ]
            .compact.join("; ")
        end
    end
  end
end
