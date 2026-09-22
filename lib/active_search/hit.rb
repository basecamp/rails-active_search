module ActiveSearch
  # Contains the search metadata attached to one loaded record.
  #
  #   article.hit.score
  #   article.hit.fields[:author_name]
  #   article.hit.highlight(:title)
  #
  # Hit and its two Hashes are frozen. The Hash values remain the objects returned by the adapter.
  class Hit
    attr_reader :score, :fields, :highlights # :nodoc:

    def initialize(score: nil, fields: {}, highlights: {}) # :nodoc:
      # Loud rather than coerced: a nil here is an adapter handing back a malformed row.
      raise ArgumentError, "fields must be a Hash, got #{fields.inspect}" unless fields.is_a?(Hash)
      raise ArgumentError, "highlights must be a Hash, got #{highlights.inspect}" unless highlights.is_a?(Hash)

      @score = score
      # Copies, frozen one level: a caller cannot add, remove or replace an entry. The values are
      # the backend's own objects and are not frozen, so a String in fields can still be mutated.
      @fields = fields.dup.freeze
      @highlights = highlights.dup.freeze
      freeze
    end

    # Returns the selected field value for a Symbol or String name.
    #
    #   article.hit.field(:author_name)
    def field(name)
      fields[name.to_sym]
    end

    # Returns the marked text for a Symbol or String field name, or nil when none was returned.
    #
    #   article.hit.highlight(:title)
    def highlight(name)
      highlights[name.to_sym]
    end

    def inspect # :nodoc:
      "#<#{self.class.name} score=#{score.inspect} fields=#{fields.keys.inspect}>"
    end

    ##
    # :attr_reader: score
    #
    # Returns the store's relevance score, or nil when the query did not produce one.

    ##
    # :attr_reader: fields
    #
    # Returns a frozen Hash of the fields selected by Query#hit_fields, keyed by Symbol.

    ##
    # :attr_reader: highlights
    #
    # Returns a frozen Hash of marked field values, keyed by Symbol.
  end
end
