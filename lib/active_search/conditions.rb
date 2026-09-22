module ActiveSearch
  # An ordered, immutable list of normalized filter predicates.
  #
  # Predicates AND together and repeated fields survive, so
  # <tt>filter(views: 100..).filter(views: ..200)</tt> keeps both bounds. Adapters iterate this
  # and never collapse it into a Hash, which is what loses the repeat.
  class Conditions # :nodoc: all
    include Enumerable

    # A single normalized predicate.
    class Condition
      attr_reader :field, :value

      # +include_missing+ adds absence to the alternatives: filter(f: nil) is "f is absent", and
      # filter(f: [ a, nil ]) is "f = a OR f is absent". Negation applies to the whole condition.
      def initialize(field:, value:, negated: false, include_missing: false)
        @field = field
        @value = value
        @negated = negated
        @include_missing = include_missing
        freeze
      end

      def negated?
        @negated
      end

      def include_missing?
        @include_missing
      end

      # A positive empty array matches nothing, so a conjunction holding one is false.
      def matches_nothing?
        empty_array? && !negated?
      end

      # A missing-only predicate: absence with no value alternatives.
      def missing_only?
        include_missing? && value.is_a?(Array) && value.empty?
      end

      # A negated empty array excludes nothing, so both partitions drop it.
      def no_op?
        empty_array? && negated?
      end

      def ==(other)
        other.is_a?(Condition) && other.field == field &&
          other.value == value && other.negated? == negated? &&
          other.include_missing? == include_missing?
      end

      def inspect
        missing = include_missing? ? " or missing" : ""
        "#<#{self.class.name} #{negated? ? "not " : ""}#{field}=#{value.inspect}#{missing}>"
      end

      private
        # An empty array carrying include_missing is a missing-value predicate rather than an
        # empty IN, so it is not one of these.
        def empty_array?
          value.is_a?(Array) && value.empty? && !include_missing?
        end
    end

    # Several alternatives, one of which has to hold. Each branch is a Conditions that ANDs. It
    # answers the same protocol as a Condition, except #field, which is nil so routing cannot read
    # a shard out of a branch that holds for only one alternative.
    class Group
      attr_reader :branches

      def initialize(branches:, negated: false)
        @branches = branches.map { |branch| branch.is_a?(Conditions) ? branch : Conditions.new(branch) }.freeze
        @negated = negated
        freeze
      end

      def negated?
        @negated
      end

      def field
        nil
      end

      def no_op?
        false
      end

      def ==(other)
        other.is_a?(Group) && other.branches == branches && other.negated? == negated?
      end

      def inspect
        "#<#{self.class.name} #{negated? ? "not " : ""}any(#{branches.map(&:inspect).join(", ")})>"
      end
    end

    def self.none
      @none ||= new
    end

    def initialize(conditions = [])
      @conditions = conditions.to_a.freeze
      freeze
    end

    def each(&block)
      @conditions.each(&block)
    end

    def +(other)
      Conditions.new(@conditions + other.to_a)
    end

    # Enumerable gives none?, not empty?, and every collection protocol expects this one.
    def empty?
      @conditions.empty?
    end

    # Both partitions drop the no-ops, so no adapter has to compile one.
    def positive
      Conditions.new(@conditions.reject { |condition| condition.negated? || condition.no_op? })
    end

    def negative
      Conditions.new(@conditions.select(&:negated?).reject(&:no_op?))
    end

    def for_field(name)
      Conditions.new(@conditions.select { |condition| condition.field == name })
    end

    def ==(other)
      other.is_a?(Conditions) && other.to_a == @conditions
    end

    def inspect
      "#<#{self.class.name} #{@conditions.map(&:inspect).join(", ")}>"
    end
  end
end
