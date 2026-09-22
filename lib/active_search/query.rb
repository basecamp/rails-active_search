module ActiveSearch
  # Builds an immutable search and returns a new Query from every chainable method.
  #
  #   query = ActiveSearch.index(:articles).search("rails")
  #     .filter(status: "published")
  #     .sort(published_at: :desc)
  #   results = query.results
  #
  # Calling a query-building method never changes the receiver. Query is not Enumerable; call
  # #results to execute it or #page to build a Page.
  class Query
    extend ActiveSupport::Autoload

    eager_autoload do
      autoload :Normalization
      autoload :Validation
    end

    include Normalization, Validation

    attr_reader :index # :nodoc:

    attr_reader :query_context
    private :query_context

    delegate :store, :definition, to: :index

    def initialize(index:, query_context: QueryContext.new, source: nil) # :nodoc:
      @index = index
      @query_context = query_context
      @source = source
    end

    # Kept out of QueryContext, which adapters read, because a source is ActiveRecord-shaped.
    def source # :nodoc:
      @source || index.source
    end

    # Sets full-text search options and returns a new Query.
    #
    #   query.search("ruby")
    #   query.search("ruby", fields: [ :title, :content ])
    #   query.search("ruby rails", operator: :and)
    #   query.search.filter(status: "published")            # filter-only
    #
    # ==== Options
    #
    # * +:fields+ - Restricts matching to a Symbol, String, or Array of named fields. All declared
    #   text fields are searched when omitted. Elasticsearch and OpenSearch also accept subfields
    #   and fields declared as +string+; other stores reject those forms.
    # * +:operator+ - Uses +:and+ or +:or+ where the store supports an explicit operator.
    #
    # Missing, nil, empty, and whitespace-only text produce a filter-only query. A second call
    # replaces the text, fields, and operator from the first. Raises QueryError for invalid text,
    # fields, or operator values, and UnsupportedOperationError when the store lacks the requested
    # field or operator support.
    def search(query = nil, fields: nil, operator: nil)
      normalized_fields = normalize_query_fields(fields)
      normalized_operator = normalize_operator(operator)
      validate_search_fields!(normalized_fields) if normalized_fields
      validate_operator!(normalized_operator)

      spawn(query_context: query_context.with(
        query: normalize_search_text(query),
        fields: normalized_fields,
        operator: normalized_operator
      ))
    end

    # Adds filter conditions with AND and returns a new Query.
    #
    #   query.filter(status: "published")           # equal to
    #   query.filter(status: [ "draft", "live" ])   # any one of
    #   query.filter(views: 100..200)               # within, either end open
    #   query.filter(status: nil)                   # field absent
    #   query.filter(status: [ "draft", nil ])      # "draft" or absent
    #
    # A scalar tests equality, an Array matches any member, an inclusive or exclusive Range tests
    # its bounds, and nil matches an absent field on stores that support missing-value filters. A
    # nil Array member also includes absence. On a field declared with +multiple: true+, a scalar
    # or Array matches documents whose collection contains any requested value.
    #
    # An empty Array matches nothing, an empty Hash has no effect, and a Range may omit either
    # endpoint. Chain calls to place two conditions on the same field. Raises QueryError for an
    # undeclared, text, or invalid value and UnsupportedOperationError when the store cannot perform
    # a missing-value or collection-range filter.
    def filter(conditions)
      spawn(query_context: query_context.add_conditions(build_conditions(conditions, negated: false)))
    end

    # Adds an OR group of filter alternatives and returns a new Query.
    #
    #   query.filter_any([ { recording_type: "Document" }, { extension: %w[ txt md ] } ])
    #   query.filter_any([ { type: "internal" }, { type: "external", approved_ids: ids } ])
    #
    # Each Array member is a Hash whose conditions use Query#filter's value forms and combine with
    # AND. The alternatives combine with OR, and the group combines with other filters through AND.
    # An empty Array matches nothing. Raises QueryError unless every alternative is a nonempty Hash.
    def filter_any(branches)
      spawn(query_context: query_context.add_conditions([ build_group(branches) ].compact))
    end

    # Excludes documents matching the complete condition Hash and returns a new Query.
    #
    #   ActiveSearch.index(:articles).reject(status: "archived")
    #   query.reject(status: "published", featured: true)
    #
    # Conditions inside one Hash combine with AND before negation. Chained calls negate each Hash
    # separately. Values use the same scalar, Array, Range, and nil forms as Query#filter;
    # +reject(status: [ "a", nil ])+ therefore requires the field to be present and not +"a"+.
    # Raises the same errors as Query#filter.
    def reject(conditions)
      spawn(query_context: query_context.add_conditions(build_negated_conditions(conditions)))
    end

    # Framework-owned constraints a caller cannot widen: a caller's value for the same field is
    # ANDed with this one, so it narrows and never replaces.
    def protect(constraints) # :nodoc:
      spawn(query_context: query_context.add_protected_conditions(build_conditions(constraints, negated: false)))
    end

    # Selects the fields returned in Hit#fields and returns a new Query.
    #
    #   query.hit_fields(:title, :content)
    #
    # Every declared field is returned when this method is not called. Raises QueryError when a
    # selected field is not declared.
    def hit_fields(*fields)
      normalized = normalize_hit_fields(fields)
      validate_hit_fields!(normalized)
      spawn(query_context: query_context.with(hit_fields: normalized))
    end

    # Requests marked matches in Hit#highlight and returns a new Query.
    #
    #   query.highlight
    #   query.highlight(title: true, content: { snippet: { words: 10 } })
    #   query.highlight(false)                                # clears an earlier highlight
    #
    # ==== Options
    #
    # * +:format+ - Uses +:html+ markers, or +:text+ markers; defaults to +:html+.
    # * +:markers+ - Uses an Array containing the opening and closing marker Strings.
    # * +:snippet+ - Passes +true+ for store defaults, <tt>{ words: n }</tt>, <tt>{ characters: n }</tt>, false,
    #   or nil. Sizes must be integers from 1 through 10,000.
    #
    # Passing true marks every searched field with defaults. A Hash names specific text fields and
    # their options. SQLite, PostgreSQL, Meilisearch, and Typesense accept word snippets;
    # Elasticsearch, OpenSearch, Solr, and Manticore accept character snippets. MySQL does not
    # support highlighting, and Redis Search supports full-field highlights without snippets.
    # Passing false clears an earlier request. Raises QueryError for invalid fields or options and
    # UnsupportedOperationError for unsupported store capabilities.
    def highlight(value = true)
      opts = value ? Highlighting::Options.new(value) : nil

      if opts
        validate_highlight_fields!(opts)
        validate_highlight_capabilities!(opts)
      end

      spawn(query_context: query_context.with(highlight_opts: opts))
    end

    # Appends the store's relevance order and returns a new Query.
    #
    #   query.sort_by_relevance
    #   query.sort_by_relevance.sort(published_at: :desc)   # relevance, then a tiebreak
    #
    # This method takes no direction because each adapter defines its own score order.
    def sort_by_relevance
      spawn(query_context: query_context.add_sort(Score))
    end

    # Appends one field order and returns a new Query.
    #
    #   query.sort(:published_at)                           # ascending; a String name also works
    #   query.sort(published_at: :desc)
    #   query.sort(account_id: :asc).sort(published_at: :desc)
    #
    # A Symbol or String sorts ascending. A one-entry Hash accepts +:asc+ or +:desc+. The field must
    # be declared as filterable and must not use +multiple: true+. Raises QueryError otherwise.
    def sort(value)
      normalized = normalize_sort(value)
      validate_sortable!(normalized)
      spawn(query_context: query_context.add_sort(normalized))
    end

    # Sets the maximum hit count and returns a new Query.
    #
    #   query.limit(50)
    #   query.limit(nil) # no explicit limit
    #
    # Values must be nonnegative and are converted to Integers. Passing nil disables the configured
    # default limit; omitting this method applies +config.active_search.default_limit+ at execution.
    # Raises QueryError for an invalid value.
    def limit(n)
      spawn(query_context: query_context.with(limit: n.nil? ? nil : normalize_pagination(n, :limit)))
    end

    # Sets the number of hits to skip and returns a new Query.
    #
    #   query.offset(100)
    #
    # Values must be nonnegative and are converted to Integers. Raises QueryError for nil or an
    # invalid value.
    def offset(n)
      spawn(query_context: query_context.with(offset: normalize_pagination(n, :offset)))
    end

    # Builds and returns one Page of this query.
    #
    #   query.page(2)
    #   query.page(2, per_page: 50)
    #   query.page(2, per_page: [ 10, 30, 50 ])
    #   query.limit(20).page(2)                 # raises
    #   query.page(400, per_page: 30)           # may exceed the store's page limit
    #
    # ==== Options
    #
    # * +:per_page+ - Uses one positive page size or an Array of positive sizes. Each page consumes
    #   the next size, and pages after the Array ends reuse its last size. The configured default
    #   limit supplies a one-element list when omitted.
    #
    # The number is converted with +to_i+ and clamped to 1. Paging ends the query chain and cannot
    # follow an explicit #limit or #offset. Raises QueryError for invalid sizes or an already limited
    # query, and ResultWindowExceeded when the requested page exceeds the store's page limit.
    def page(number, per_page: nil)
      validate_unwindowed!

      size = per_page.nil? ? Rails.application.config.active_search.default_limit : per_page
      if size.nil?
        raise QueryError,
          "page needs a page size, and config.active_search.default_limit is nil. Pass per_page:."
      end

      page = Page.new(self, number: normalize_page_number(number), per_page: normalize_per_page(size))
      store.ensure_within_result_window!(query_context.with(limit: page.limit, offset: page.offset))
      page
    end

    # Builds and returns the query in the configured store's native form.
    #
    #   native_query = query.to_native_query
    #
    # Database adapters return an ActiveRecord::Relation, and other adapters return a Hash. This
    # method applies defaults and #native blocks but does not execute the request or enforce the
    # store's page limit. Routing is returned separately by #routing.
    def to_native_query
      ctx = query_context_with_defaults
      store.build_query(index, ctx, routing: routing)
    end

    # Returns the routing value or values resolved from this query's filters.
    #
    #   Post.search("q").filter(account_id: 1).routing          # => 1
    #   Post.search("q").filter(account_id: [ 1, 2 ]).routing   # => [ 1, 2 ]
    #   Post.search("q").routing                                # => nil
    #
    # Returns nil when the query reads every shard. Raises QueryError when filters on the routing
    # field cannot identify a valid set of shards. Elasticsearch and OpenSearch send this value
    # outside the request body, so #to_native_query does not include it.
    def routing
      Routing.resolve(index.route_by, query_context_with_defaults)
    end

    # Adds a native request transformation and returns a new Query.
    #
    #   query.native { |request| request[:timeout] = "5s"; request }
    #
    # The block receives the built native query and must return the request to execute. It runs
    # after validation, and its result is not checked, so trusted application code can weaken model
    # constraints or change the requested page. It cannot add undeclared values to Hit#fields.
    # Raises QueryError when called without a block. Exceptions from the block pass through.
    def native(&block)
      raise QueryError, "native requires a block" unless block_given?
      spawn(query_context: query_context.add_modifier(&block))
    end

    def with_source(object) # :nodoc:
      unless Source::Base::CUSTOM_CONTRACT.all? { |method| object.respond_to?(method) }
        raise QueryError,
          "a source must answer #{Source::Base::CUSTOM_CONTRACT.join(" and ")}, and " \
          "#{object.class} does not"
      end

      spawn(source: object)
    end

    # Executes the query and returns Results containing the loaded records.
    #
    #   results = query.results
    #
    # A query without an explicit #limit uses +config.active_search.default_limit+. Each call
    # executes again and emits +search.active_search+ around the store request. Store failures raise
    # AdapterError; invalid or unsupported query operations raise their QueryError subclasses.
    def results
      ctx = query_context_with_defaults
      routing = Routing.resolve(index.route_by, ctx)

      # The payload reaches every subscriber and the log, so it includes the query's length rather
      # than the end-user text.
      payload = {
        index: index.name,
        store_name: index.configured_store_name,
        query_length: ctx.query.to_s.length
      }

      data = ActiveSupport::Notifications.instrument("search.active_search", payload) do |p|
        result = store.search(index, ctx, routing: routing)
        p[:total] = result[:total]
        p[:total_relation] = result.fetch(:total_relation, :equal)
        p[:partial_results] = result.fetch(:partial_results, false)
        # Absent rather than empty when a store reports nothing, so zero never reads as a measurement.
        p[:store_metrics] = result[:store_metrics] if result[:store_metrics].present?
        result
      end

      Results.new(
        data[:results],
        total: data[:total],
        total_relation: data.fetch(:total_relation, :equal),
        definition: definition,
        source: source,
        type_casters: store.type_casters,
        limit: ctx.limit,
        offset: ctx.offset,
        fetched_extra_hit: data.fetch(:fetched_extra_hit, false),
        partial: data.fetch(:partial_results, false)
      )
    end

    private
      def spawn(query_context: self.query_context, source: @source)
        Query.new(index: index, query_context: query_context, source: source)
      end

      def query_context_with_defaults
        ctx = query_context
        ctx = ctx.with(fields: definition.search_fields) if ctx.fields.nil?
        ctx = ctx.with(limit: Rails.application.config.active_search.default_limit) if ctx.limit_unset?
        ctx
      end
  end
end
