module ActiveSearch
  module StoreAdapters
    class Solr
      module ResponseParsing # :nodoc: all
        private
          def parse_response(response, highlight_opts, highlight_fields)
            docs = response.dig("response", "docs") || []
            total = response.dig("response", "numFound") || 0
            highlighting = response["highlighting"] || {}

            results = docs.map do |doc|
              parse_doc(doc, highlighting, highlight_opts, highlight_fields)
            end

            # An incomplete page can only undercount, and Solr sends no relation to say so.
            partial = partial_results?(response)
            # numFoundExact false means Solr stopped counting (minExactCount), so the total is a floor.
            inexact = partial || response.dig("response", "numFoundExact") == false

            { total: total, total_relation: inexact ? :lower_bound : :equal, results: results,
              partial_results: partial, store_metrics: store_metrics_for(response) }
          end

          # QTime is Solr's own query time in milliseconds, excluding transport.
          def store_metrics_for(response)
            { took: response.dig("responseHeader", "QTime") }
          end

          # partialResults appears when a limit was exceeded, so the page is incomplete.
          def partial_results?(response)
            response.dig("responseHeader", "partialResults") == true
          end

          def parse_doc(doc, highlighting, highlight_opts, highlight_fields)
            stored_id = doc["id"]
            doc_highlights = highlighting[stored_id] || {}

            highlights = if highlight_opts
              extract_highlights(doc_highlights, highlight_opts, highlight_fields)
            else
              {}
            end

            fields = doc.except("id", "score", "_version_").deep_symbolize_keys

            {
              id: model_id_to_gid(stored_id),
              score: doc["score"]&.to_f || 1.0,
              fields: fields,
              highlights: highlights
            }
          end
      end
    end
  end
end
