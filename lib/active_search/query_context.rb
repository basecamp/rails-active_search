module ActiveSearch
  # Tells "no limit was asked for", which takes the configured default, from limit(nil), which asks
  # for none at all. Outside the Data block, where a constant would not land on the class.
  LIMIT_UNSET = Object.new.freeze
  private_constant :LIMIT_UNSET

  # The validated state of a query, in the form an adapter reads. A Data, so instances are frozen
  # and #with copies; the add_* methods below append to a member rather than replacing it.
  QueryContext = Data.define( # :nodoc:
    :query, :fields, :conditions, :protected_conditions, :sort,
    :limit, :offset, :highlight_opts, :hit_fields, :modifiers, :operator
  ) do
    def self.unset
      LIMIT_UNSET
    end

    def initialize(
      query: nil,
      fields: nil,
      conditions: Conditions.none,
      protected_conditions: Conditions.none,
      sort: [],
      limit: LIMIT_UNSET,
      offset: nil,
      highlight_opts: nil,
      hit_fields: nil,
      modifiers: [],
      operator: nil
    )
      super
    end

    def limit_unset?
      limit.equal?(QueryContext.unset)
    end

    # Every predicate the backend must apply, framework-owned first. They AND, so a caller naming
    # a protected field narrows the constraint rather than widening it.
    def all_conditions
      protected_conditions + conditions
    end

    def add_conditions(new_conditions)
      with(conditions: conditions + new_conditions)
    end

    def add_protected_conditions(new_conditions)
      with(protected_conditions: protected_conditions + new_conditions)
    end

    def add_modifier(&block)
      with(modifiers: modifiers + [ block ])
    end

    def add_sort(value)
      with(sort: sort + [ value ])
    end
  end
end
