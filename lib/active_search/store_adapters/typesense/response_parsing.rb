module ActiveSearch
  module StoreAdapters
    class Typesense
      module ResponseParsing # :nodoc: all
        private
          def parse_response(response, highlight_opts, highlight_fields)
            hits = response["hits"] || []
            total = response["found"] || 0

            results = hits.map do |hit|
              parse_hit(hit, highlight_opts, highlight_fields)
            end

            # A cutoff stopped the search early, so found can only undercount.
            cutoff = response["search_cutoff"] == true

            { total: total, total_relation: cutoff ? :lower_bound : :equal, results: results,
              partial_results: cutoff, store_metrics: store_metrics_for(response) }
          end

          def store_metrics_for(response)
            { took: response["search_time_ms"] }
          end

          def parse_hit(hit, highlight_opts, highlight_fields)
            doc = hit["document"] || {}
            highlight_data = hit["highlights"] || []

            highlights = if highlight_opts
              extract_highlights(highlight_data, highlight_opts, highlight_fields)
            else
              {}
            end

            fields = doc.except("id").deep_symbolize_keys

            {
              id: model_id_to_gid(doc["id"].to_s),
              score: (hit["text_match"] || 0).to_f,
              fields: fields,
              highlights: highlights
            }
          end
      end
    end
  end
end
