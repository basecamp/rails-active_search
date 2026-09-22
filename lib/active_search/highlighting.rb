module ActiveSearch
  # = ActiveSearch::Highlighting
  #
  # The highlighting part of the adapter contract. An adapter reads the Options on the query
  # context, wraps each match in the markers below, and passes each value to ::fragment.
  module Highlighting # :nodoc:
    extend ActiveSupport::Autoload

    autoload :Options
    autoload :FieldOptions

    # What every adapter marks matches with. Private-use codepoints rather than the configured
    # markers, which a document's own text could forge, and ::fragment returns nil without them.
    STORE_OPEN_MARKER = "\uE000"
    STORE_CLOSE_MARKER = "\uE001"

    # What a snippet puts where it cut the text; an unmarked cut reads as the whole field.
    SNIPPET_ELLIPSIS = "..."

    # Escapes before substituting the markers, so only an engine-marked match renders as one.
    def self.escape_html(text, field_opts)
      if field_opts.html?
        CGI.escapeHTML(text)
          .gsub(STORE_OPEN_MARKER, field_opts.open_marker)
          .gsub(STORE_CLOSE_MARKER, field_opts.close_marker)
          .html_safe
      else
        text
          .gsub(STORE_OPEN_MARKER, field_opts.open_marker)
          .gsub(STORE_CLOSE_MARKER, field_opts.close_marker)
      end
    end

    # Only a marked value is a highlight. A store that matched nothing still answers: SQLite returns
    # the whole column and Redis Search returns the whole field, both unmarked.
    def self.fragment(text, field_opts)
      if text.present? && text.include?(STORE_OPEN_MARKER)
        escape_html(text, field_opts)
      end
    end

    # Which fields to highlight: the ones the caller named, or all of them when they named none.
    def self.fields_for(all_fields, opts)
      opts&.specific_fields? ? opts.requested_fields : all_fields
    end
  end
end
