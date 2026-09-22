module ActiveSearch
  # A backend-reported hit count and how much it can be trusted. The public reader is
  # {Results#total}, a plain Integer.
  #
  #   Total.new(value: 1_000, relation: :equal)
  #   Total.new(value: 10_000, relation: :lower_bound)   # capped tracking
  #   Total.new(value: 980, relation: :estimate)
  class Total # :nodoc:
    RELATIONS = %i[equal lower_bound estimate].freeze

    attr_reader :value, :relation

    def initialize(value:, relation: :equal)
      unless RELATIONS.include?(relation)
        raise ArgumentError, "relation must be one of #{RELATIONS.join(", ")}, got #{relation.inspect}"
      end

      @value = value.to_i
      @relation = relation
      freeze
    end

    def exact?
      relation == :equal
    end

    def to_i
      value
    end

    def inspect
      "#<#{self.class.name} #{value} #{relation}>"
    end
  end
end
