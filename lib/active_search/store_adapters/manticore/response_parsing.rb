module ActiveSearch
  module StoreAdapters
    class Manticore
      module ResponseParsing # :nodoc: all
        private
          def parse_response(response, highlight_opts, highlight_fields)
            hits = response.dig("hits", "hits") || []
            total = response.dig("hits", "total") || 0
            # "gte" means the count was capped. A timeout means it stopped early, which undercounts
            # whatever the relation says.
            timed_out = response["timed_out"] == true
            capped = response.dig("hits", "total_relation") == "gte"
            total_relation = capped || timed_out ? :lower_bound : :equal

            results = hits.map do |hit|
              parse_hit(hit, highlight_opts, highlight_fields)
            end

            { total: total, total_relation: total_relation, results: results,
              partial_results: timed_out, store_metrics: store_metrics_for(response) }
          end

          def store_metrics_for(response)
            { took: response["took"] }
          end

          def parse_hit(hit, highlight_opts, highlight_fields)
            source = hit["_source"] || {}
            stored_id = source["_original_id"] || hit["_id"].to_s
            id = model_id_to_gid(stored_id)
            score = hit["_score"].to_f

            highlights = if highlight_opts && highlight_fields.present?
              extract_highlights(hit["highlight"] || {}, highlight_opts, highlight_fields)
            else
              {}
            end

            fields = source.except("_original_id").deep_symbolize_keys

            {
              id: id,
              score: score,
              fields: fields,
              highlights: highlights
            }
          end
      end
    end
  end
end
