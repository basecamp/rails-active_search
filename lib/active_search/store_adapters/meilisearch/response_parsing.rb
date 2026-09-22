module ActiveSearch
  module StoreAdapters
    class Meilisearch
      module ResponseParsing # :nodoc: all
        private
          def parse_response(response, highlight_opts, highlight_fields)
            hits = response["hits"] || []
            exact = response.key?("totalHits") || !response.key?("estimatedTotalHits")
            total = response["totalHits"] || response["estimatedTotalHits"] || hits.size
            total_relation = exact ? :equal : :estimate

            results = hits.map do |hit|
              formatted = hit["_formatted"] || {}
              source = hit.except("_formatted", "_matchesPosition", "_rankingScore", "id")

              highlights = if highlight_opts
                extract_highlights(formatted, highlight_opts, highlight_fields)
              else
                {}
              end

              fields = source.deep_symbolize_keys

              {
                id: model_id_to_gid(decode_id(hit["id"].to_s)),
                score: hit["_rankingScore"] || 1.0,
                fields: fields,
                highlights: highlights
              }
            end

            { total: total, total_relation: total_relation, results: results,
              store_metrics: { took: response["processingTimeMs"] } }
          end
      end
    end
  end
end
