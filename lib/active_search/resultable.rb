module ActiveSearch
  # Gives a loaded search result access to its Hit metadata.
  #
  # +has_search+ includes Resultable automatically. Objects returned by a custom source must
  # include it themselves.
  #
  #   class Card
  #     include ActiveSearch::Resultable
  #   end
  #
  # An object that did not come from a search returns nil rather than an empty Hit.
  module Resultable
    # Returns the Hit attached by the most recent search, or nil when none has been attached.
    def hit
      @_active_search_hit
    end

    # Loading the records attaches the Hit. The metadata stays on this instance for its lifetime; a
    # later search returning the same record replaces it.
    def hit=(value) # :nodoc:
      @_active_search_hit = value
    end
  end
end
