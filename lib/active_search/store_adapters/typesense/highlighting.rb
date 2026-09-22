module ActiveSearch
  module StoreAdapters
    class Typesense
      module Highlighting # :nodoc: all
        private
          def extract_highlights(highlight_data, opts, highlight_fields)
            snippets = highlight_data.to_h { |hl| [ hl["field"].to_sym, hl["snippet"] ] }

            highlight_fields.each_with_object({}) do |field, h|
              field_opts = opts.for_field(field)
              snippet = snippets[field]
              next unless snippet.is_a?(String)

              fragment = ActiveSearch::Highlighting.fragment(snippet, field_opts)
              h[field] = fragment if fragment
            end
          end
      end
    end
  end
end
