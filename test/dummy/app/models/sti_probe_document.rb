class StiProbeDocument < ApplicationRecord
  # type is a declared field here, and would otherwise make this table
  # single table inheritance.
  self.inheritance_column = nil
end
