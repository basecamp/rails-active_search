module ActiveSearch
  # Internal marker for relevance in a sort list; callers use Query#sort_by_relevance. A
  # module rather than a symbol, so it cannot collide with a field named "score". Reference it
  # lexically from inside ActiveSearch — private_constant blocks the qualified path.
  module Score # :nodoc:
    def self.to_s
      "Score"
    end

    def self.inspect
      "ActiveSearch::Score"
    end
  end
end
