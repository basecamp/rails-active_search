module ActiveSearch
  module StoreAdapters
    class Elastic
      module ResponseParsing # :nodoc: all
        private
          def parse_response(response, highlight_opts, highlight_fields)
            # ES 8 answers a Response with .body; ES 7 and OpenSearch answer a plain Hash.
            data = response.respond_to?(:body) ? response.body : response
            hits_data = data["hits"]
            hits = hits_data["hits"]

            # ES7 sends a bare Integer total, which dig would raise on rather than read.
            raw_total = hits_data["total"]
            total = raw_total.is_a?(Hash) ? raw_total["value"] : raw_total
            # A partial answer counts only what it reached, and Elasticsearch still marks it "eq".
            total_relation = if (raw_total.is_a?(Hash) && raw_total["relation"] == "gte") || partial_results?(data)
              :lower_bound
            else
              :equal
            end

            results = hits.map do |hit|
              raw_highlights = hit["highlight"] || {}
              source = hit["_source"] || {}

              highlights = if highlight_opts
                extract_highlights(raw_highlights, highlight_opts, highlight_fields)
              else
                {}
              end

              fields = source.deep_symbolize_keys

              {
                id: model_id_to_gid(hit["_id"]),
                score: hit["_score"].to_f,
                fields: fields,
                highlights: highlights
              }
            end

            { total: total, total_relation: total_relation, results: results,
              partial_results: partial_results?(data), store_metrics: store_metrics_for(data) }
          end

          # took is Elasticsearch's own time, excluding transport, so it is not the event duration.
          def store_metrics_for(data)
            {
              took: data["took"],
              shards_failed: data.dig("_shards", "failed"),
              timed_out: data["timed_out"],
              terminated_early: data["terminated_early"]
            }
          end

          # All three leave the answer smaller than the query described. terminate_after counts too:
          # unlike a limit it never reaches next_page?, so the page reads as one of several when
          # none follows it.
          def partial_results?(data)
            data["timed_out"] == true ||
              data.dig("_shards", "failed").to_i.positive? ||
              data["terminated_early"] == true
          end
      end
    end
  end
end
