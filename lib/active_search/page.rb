module ActiveSearch
  # Represents one fixed page built by Query#page.
  #
  #   page = Article.search("ruby").page(2, per_page: 20)
  #   page.results.each { |article| ... }
  #   page.number      # => 2
  #   page.next?       # => true
  #
  # A Page ends the query chain. The loaded records and totals are available through #results.
  #
  # +per_page+ may be a list of sizes. Each page takes the next size, and every page after the list
  # uses the final size.
  #
  #   page(n, per_page: [ 10, 30, 50 ])   # 10, then 30, then 50 from page 3 on
  #
  class Page
    attr_reader :number, :per_page # :nodoc:

    def initialize(query, number:, per_page:) # :nodoc:
      @number = number
      @per_page = per_page
      @query = query
    end

    # Executes this page's query once and returns its memoized Results.
    def results
      @results ||= @query.limit(limit).offset(offset).results
    end

    # Returns the maximum number of hits requested for this page.
    #
    # Fewer records may be returned when the store has fewer hits or some hits cannot be loaded.
    def limit
      per_page[number - 1] || per_page.last
    end

    # Returns the sum of the sizes of every page before this one.
    def offset
      grown = [ number - 1, per_page.length - 1 ].min

      grown.times.sum { |index| per_page[index] } +
        [ number - per_page.length, 0 ].max * per_page.last
    end

    # Returns true when the store reports hits beyond this page.
    #
    # Index hits count even when their records are missing or excluded by a loading scope, so the
    # next page may still contain no records. On a partial page, false means the store returned no
    # further hit before stopping.
    def next?
      results.next_page?
    end

    # Returns true when this page follows the first page.
    def previous?
      number > 1
    end

    # Returns the number of pages needed for Results#total at the configured page sizes.
    #
    # Uneven sizes are summed before the final size is reused. The count is only as exact as
    # Results#total.
    def page_count
      remaining = results.total
      count = 0

      per_page.each do |size|
        break unless remaining.positive?
        count += 1
        remaining -= size
      end

      count += (remaining + per_page.last - 1) / per_page.last if remaining.positive?
      count
    end

    def inspect # :nodoc:
      "#<#{self.class.name} number=#{number} per_page=#{per_page.inspect}>"
    end

    ##
    # :attr_reader: number
    #
    # Returns this page's positive, normalized page number.

    ##
    # :attr_reader: per_page
    #
    # Returns the frozen Array of page sizes, including a one-element Array for a scalar size.
  end
end
