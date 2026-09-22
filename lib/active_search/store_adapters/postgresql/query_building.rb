module ActiveSearch
  module StoreAdapters
    class Postgresql
      module QueryBuilding # :nodoc: all
        private
          # @> answers membership and nothing else, so a range unrolls the collection with
          # jsonb_array_elements. #>>'{}' takes the element as text, cast to numeric where the
          # elements are numbers -- a datetime is stored as its ISO string and orders as text.
          def collection_range_sql(scope, column, range, numeric)
            low, high, exclusive = range_bounds(range)
            element = numeric ? "(e.value #>> '{}')::numeric" : "e.value #>> '{}'"
            tests = []
            tests << scope.model.sanitize_sql_array([ "#{element} >= ?", low ]) unless low.nil?
            tests << scope.model.sanitize_sql_array([ "#{element} #{exclusive ? '<' : '<='} ?", high ]) unless high.nil?
            return "1 = 1" if tests.empty?

            "EXISTS (SELECT 1 FROM jsonb_array_elements(#{column}) AS e WHERE #{tests.join(' AND ')})"
          end
          # @> asks whether the stored collection contains the one on the right, so overlap is that
          # test once per value. jsonb, not json: @> is a jsonb operator, which is why the migration
          # picks the column type it does.
          def collection_overlap_sql(scope, column, values)
            return "1 = 0" if values.empty?

            tests = values.map do |value|
              scope.model.sanitize_sql_array([ "#{column} @> ?::jsonb", [ value ].to_json ])
            end

            "(#{tests.join(' OR ')})"
          end
          def apply_search(model, query_context, index, routing:)
            fields = query_context.fields
            vector_cols = fields.map { |f| "#{f}_vector" }.join(" || ")
            tsquery = build_tsquery(model, query_context)

            model
              .select(Arel.sql(id_select_sql(model, index)), "ts_rank(#{vector_cols}, #{tsquery}) AS score")
              .where(Arel.sql("(#{vector_cols}) @@ #{tsquery}"))
          end

          # websearch_to_tsquery parses the user's own phrases, -exclusions and OR, so the query
          # goes through unchanged.
          def build_tsquery(model, query_context)
            conn = model.connection
            "websearch_to_tsquery('english', #{conn.quote(query_context.query.to_s)})"
          end
      end
    end
  end
end
