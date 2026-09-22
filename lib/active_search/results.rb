module ActiveSearch
  # Contains the application records returned by Query#results and their aggregate metadata.
  #
  # Results includes Enumerable. Iteration loads records through the index source and attaches each
  # record's score, selected fields, and highlights as a Hit.
  #
  #   results = Article.search("rails").results
  #   results.each { |article| puts article.hit.score }
  class Results
    include Enumerable

    # +fetched_extra_hit+ says the raw rows hold one hit beyond the requested page. Only the
    # adapter knows whether it asked for that hit.
    def initialize(raw_results, total:, definition:, source:, type_casters: {}, # :nodoc:
                   limit: nil, offset: nil, total_relation: :equal, fetched_extra_hit: false,
                   partial: false)
      @total = Total.new(value: total.to_i, relation: total_relation)
      @partial = partial
      @limit = limit
      @offset = offset
      @definition = definition
      @source = source
      @type_casters = type_casters

      # The extra hit supports next_page? and must not reach record loading.
      @fetched_extra_hit = fetched_extra_hit
      @extra_hit = fetched_extra_hit && !limit.nil? && raw_results.size > limit
      @raw_results = @extra_hit ? raw_results.first(limit) : raw_results
    end

    # Returns the number of matching index hits across all pages.
    #
    # A stale document or a record excluded by the loading scope still contributes to this count.
    def total
      @total.value
    end

    # Returns true when #total is exact rather than a lower bound or estimate.
    def total_exact?
      @total.exact?
    end

    # Returns the number of this page's hits that could not be loaded as records.
    #
    # A missing record or loading scope can increase this count. It is independent of #partial?,
    # which reports whether the store stopped before returning all hits for the requested page.
    def dropped
      total_for_page = @raw_results.size
      total_for_page - built_results.size
    end

    # Returns true when the store stopped early and returned an incomplete page.
    #
    # Stores without an incomplete-page mode always return false.
    def partial?
      @partial
    end

    delegate :size, :length, :count, :empty?, to: :built_results # :nodoc:

    # Yields each loaded record and returns self, or returns an Enumerator without a block.
    def each(&block)
      if block
        built_results.each(&block)
        self
      else
        # Keep the Enumerator's receiver as Results rather than exposing the memoized Array.
        enum_for(:each)
      end
    end

    # The raw page size avoids loading records during inspection.
    def inspect # :nodoc:
      "#<#{self.class.name} total: #{total}, hits: #{@raw_results.size}>"
    end

    # Returns true when the store reports hits beyond this page.
    #
    # This uses an extra fetched hit when the adapter requests one and otherwise compares the page
    # position with #total. A missing source record does not change the result. With an inexact total
    # the result may be approximate; on a partial page, false means the store returned no further
    # hit before stopping.
    def next_page?
      if @fetched_extra_hit
        @extra_hit
      else
        (@offset || 0) + @raw_results.size < total
      end
    end

    private
      def built_results
        @built_results ||= build_results
      end

      def build_results
        build_record_results
      end

      def build_record_results
        ids = @raw_results.map { |r| r[:id] }.compact.uniq
        loaded_records = @source.records_for(ids)
        # Keyed as strings to match the lookup below: a source's id_for may return an Integer.
        records_by_id = loaded_records.index_by { |r| @source.id_for(r).to_s }

        # A hit whose record is gone is expected and counted by #dropped.
        @raw_results.filter_map do |row|
          record = records_by_id[row[:id].to_s]
          next if record.nil?

          set_hit_attrs(record, row)
          record
        end
      end

      def set_hit_attrs(obj, row)
        casted_fields = cast_fields(row[:fields], @definition)
        obj.hit = Hit.new(
          score: row[:score],
          fields: casted_fields,
          highlights: row[:highlights]
        )
      end

      def cast_fields(fields, schema)
        return fields unless schema
        return fields if @type_casters.empty?

        fields.to_h do |key, value|
          field_name = key.to_sym
          field = schema[field_name]
          casted = field ? cast_value(value, field.type) : value
          [ field_name, casted ]
        end
      end

      # A multiple: field arrives as a collection, and every caster refuses one, so the caster is
      # mapped over it. Only the store's own casters run here -- the field's type already cast the
      # value on the way in.
      def cast_value(value, type)
        return value if value.nil?
        caster = @type_casters[type]
        return value unless caster

        if value.is_a?(Array)
          value.map { |member| member.nil? ? member : caster.cast(member) }
        else
          caster.cast(value)
        end
      end

    public

    ##
    # :method: size
    # :call-seq: size -> integer
    #
    # Returns the number of loaded records on this page.

    ##
    # :method: length
    # :call-seq: length -> integer
    #
    # Returns the number of loaded records on this page.

    ##
    # :method: count
    # :call-seq:
    #   count -> integer
    #   count(record) -> integer
    #   count { |record| ... } -> integer
    #
    # Returns the number of loaded records, the number equal to +record+, or the number for which
    # the block returns true.

    ##
    # :method: empty?
    # :call-seq: empty? -> true or false
    #
    # Returns true when this page contains no loaded records.
  end
end
