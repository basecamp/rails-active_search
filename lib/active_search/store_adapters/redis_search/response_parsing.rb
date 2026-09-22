module ActiveSearch
  module StoreAdapters
    class RedisSearch
      module ResponseParsing # :nodoc: all
        private
          # RESP2 replies with a flat array, RESP3 with a map. Only the map carries a warning,
          # which is Redis saying it stopped early -- a timeout or a cut-off, so a partial page.
          def parse_response(response, highlight_opts, highlight_fields, index_name, definition = nil)
            documents, total, partial = if response.is_a?(Hash)
              [ parse_resp3_documents(response), response["total_results"], response["warning"].present? ]
            else
              [ parse_resp2_documents(response), response[0], false ]
            end

            prefix = "#{index_name}:"

            results = documents.map do |doc_key, score, fields_hash|
              highlights = if highlight_opts && highlight_fields.present?
                extract_highlights(fields_hash, highlight_opts, highlight_fields)
              else
                {}
              end

              {
                id: model_id_to_gid(doc_key.sub(prefix, "")),
                score: score.to_f,
                fields: split_collections(unmarked_fields(fields_hash, highlight_opts, highlight_fields), definition),
                highlights: highlights
              }
            end

            # A cut-off answer counted only what it reached, so its total is a floor, not a count.
            { total: total, total_relation: partial ? :lower_bound : :equal,
              results: results, partial_results: partial }
          end

          # HIGHLIGHT rewrites the attribute values themselves, so the raw value only comes back
          # by stripping the markers. Writes strip them from document text, so any marker in a
          # response is the engine's.
          def unmarked_fields(fields_hash, opts, highlight_fields)
            return fields_hash unless opts && highlight_fields.present?

            fields_hash.to_h do |name, value|
              if value.is_a?(::String) && highlight_fields.include?(name)
                [ name, value.gsub(ActiveSearch::Highlighting::STORE_OPEN_MARKER, "")
                             .gsub(ActiveSearch::Highlighting::STORE_CLOSE_MARKER, "") ]
              else
                [ name, value ]
              end
            end
          end

          # A collection was written joined, so it comes back as one string. An empty one splits to
          # [], which is what an empty collection was.
          def split_collections(fields_hash, definition)
            return fields_hash unless definition

            fields_hash.to_h do |name, value|
              field = definition[name]
              if field&.multiple? && value.is_a?(::String)
                [ name, value.split(RedisSearch::COLLECTION_SEPARATOR) ]
              else
                [ name, value ]
              end
            end
          end

          def parse_resp2_documents(response)
            response[1..].each_slice(3).map do |doc_key, score, doc_fields|
              [ doc_key, score, Hash[*doc_fields].transform_keys(&:to_sym) ]
            end
          end

          def parse_resp3_documents(response)
            response["results"].map do |result|
              attributes = result["extra_attributes"] || {}
              [ result["id"], result["score"], attributes.transform_keys(&:to_sym) ]
            end
          end
      end
    end
  end
end
