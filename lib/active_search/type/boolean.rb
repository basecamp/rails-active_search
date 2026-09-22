module ActiveSearch
  module Type # :nodoc: all
    # Nothing to add: Active Model answers true, false or nil for every input, and Canonical refuses
    # the nil.
    class Boolean < ActiveModel::Type::Boolean
      include Canonical
    end
  end
end
