module ActiveSearch
  # Describes the query and index-management features supported by a store adapter.
  #
  # Query validates requested operations against these values before it builds a native request.
  # Custom adapters return a frozen Capabilities instance from StoreAdapters::Base#capabilities.
  class Capabilities
    ##
    # :attr_reader: max_result_window
    #
    # Returns the largest supported <tt>offset + limit</tt>, or nil when the store declares no page limit.
    attr_reader :max_result_window

    # Builds and returns a frozen capability description.
    #
    # ==== Options
    #
    # * +:highlighting+ - Enables highlighting; defaults to true.
    # * +:highlight_snippet_units+ - Lists supported +:words+ and +:characters+ snippet units.
    # * +:highlight_per_field_markers+ - Allows different markers for different fields.
    # * +:highlight_per_field_snippets+ - Allows different snippet settings for different fields.
    # * +:operator+ - Enables the Query#search +:operator+ option.
    # * +:missing_filters+ - Enables filtering for absent fields.
    # * +:index_creation+ - Enables index creation from the declaration.
    # * +:search_subfields+ - Enables searching a subfield of a declared text field.
    # * +:search_string_fields+ - Enables full-text search on a field declared as +string+.
    # * +:approximate_totals+ - Allows totals that are estimates or lower bounds.
    # * +:collection_ranges+ - Enables Range filters on fields declared with +multiple: true+.
    # * +:max_result_window+ - Sets the store's largest supported <tt>offset + limit</tt>, or nil for no
    #   declared page limit.
    def initialize(
      highlighting: true,
      highlight_snippet_units: Highlighting::FieldOptions::UNITS,
      highlight_per_field_markers: true,
      highlight_per_field_snippets: true,
      operator: true,
      missing_filters: true,
      index_creation: false,
      search_subfields: false,
      search_string_fields: false,
      approximate_totals: false,
      collection_ranges: false,
      max_result_window: nil
    )
      @highlighting = highlighting
      # Copied before freezing, or the caller keeps a mutable Array that every validation reads.
      @highlight_snippet_units = Array(highlight_snippet_units).dup.freeze
      @highlight_per_field_markers = highlight_per_field_markers
      @highlight_per_field_snippets = highlight_per_field_snippets
      @operator = operator
      @missing_filters = missing_filters
      @index_creation = index_creation
      @search_subfields = search_subfields
      @search_string_fields = search_string_fields
      @approximate_totals = approximate_totals
      @collection_ranges = collection_ranges
      @max_result_window = max_result_window
      freeze
    end

    # Returns true when the store supports highlighting.
    def supports_highlighting?
      @highlighting
    end

    # Returns true when the store supports +unit+ for highlight snippets.
    def supports_snippet_unit?(unit)
      @highlight_snippet_units.include?(unit)
    end

    # Returns true when separate fields may use different highlight markers.
    def supports_highlight_per_field_markers?
      @highlight_per_field_markers
    end

    # Returns true when separate fields may use different snippet settings.
    def supports_highlight_per_field_snippets?
      @highlight_per_field_snippets
    end

    # Returns true when Query#search accepts an explicit +:operator+.
    def supports_operator?
      @operator
    end

    # Returns true when filters may test whether a field is absent.
    def supports_missing_filters?
      @missing_filters
    end

    # Returns true when ActiveSearch can create an index directly or by writing a migration.
    def supports_index_creation?
      @index_creation
    end

    # Returns true when search and highlighting accept +BASE.SUFFIX+ for a declared text field.
    #
    # ActiveSearch validates the name but does not create or inspect the subfield mapping.
    def supports_search_subfields?
      @search_subfields
    end

    # Returns true when full-text search accepts a field declared only as +string+.
    #
    # Exact matching remains available through Query#filter.
    def supports_search_string_fields?
      @search_string_fields
    end

    # Returns true when a store may report a lower-bound or estimated total.
    #
    # Results#total_exact? reports whether a particular response was exact.
    def approximate_totals?
      @approximate_totals
    end

    # Returns true when a Range can match one element of a +multiple: true+ field.
    def supports_collection_ranges?
      @collection_ranges
    end
  end
end
