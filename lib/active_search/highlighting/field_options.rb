module ActiveSearch
  module Highlighting
    # One field's highlight settings, validated on the way in so an adapter can read the markers,
    # format and snippet size without re-checking them.
    class FieldOptions # :nodoc:
      UNITS = %i[ words characters ].freeze

      DEFAULT_OPEN = "<mark>"
      DEFAULT_CLOSE = "</mark>"
      DEFAULT_SNIPPET_WORDS = 20
      DEFAULT_SNIPPET_CHARS = 140

      VALID_FORMATS = %i[html text].freeze
      VALID_OPTIONS = %i[format markers snippet].freeze

      # Only backend names that translate into an option this API already has. Anything else, such
      # as Elasticsearch's type, goes through native.
      NATIVE_EQUIVALENTS = {
        pre_tags: :markers, post_tags: :markers, tags: :markers,
        highlight_pre_tag: :markers, highlight_post_tag: :markers,
        highlight_start_tag: :markers, highlight_end_tag: :markers,
        fragment_size: :snippet, number_of_fragments: :snippet,
        crop_length: :snippet, highlight_affix_num_tokens: :snippet
      }.freeze

      SAFE_TAGS = %w[mark em strong b i u s span small code ins del].freeze
      HTML_MARKER = /\A(?:<\/?(?:#{Regexp.union(SAFE_TAGS).source})(?:\s+(?:class|id)="[-\w ]*")*>)+\z/
      TEXT_MARKER = /\A[^"'\\]{1,32}\z/

      MAX_SNIPPET_SIZE = 10_000

      attr_reader :open_marker, :close_marker, :format, :snippet_unit, :snippet_value

      # true - use defaults (full highlight, html format)
      # { snippet: true } - default snippet
      # { snippet: { words: 10 } } - word-based snippet
      # { snippet: { characters: 100 } } - character-based snippet
      # { markers: ["<em>", "</em>"], format: :text }
      def initialize(value = {})
        value = value == true ? {} : value
        validate_options!(value)
        value = value.symbolize_keys

        @format = parse_format(value[:format])
        parse_markers(value[:markers])
        parse_snippet(value[:snippet])
      end

      def snippet?
        @snippet_unit != nil
      end

      def html?
        @format == :html
      end

      private
        # An unknown key raises: dropped, it would read as configured and do nothing.
        def validate_options!(value)
          unless value.is_a?(Hash)
            raise QueryError, "Highlight options must be true or a Hash, got #{value.inspect}"
          end

          unknown = value.keys.map(&:to_sym) - VALID_OPTIONS
          return if unknown.empty?

          raise QueryError, "Unknown highlight #{"option".pluralize(unknown.size)} " \
            "#{unknown.map(&:inspect).join(", ")}. Valid: #{VALID_OPTIONS.join(", ")}." \
            "#{equivalent_hint(unknown)} Pass a backend's own highlight options through native."
        end

        # Grouped by target, because Elasticsearch pairs pre_tags with post_tags.
        def equivalent_hint(unknown)
          grouped = unknown.filter_map { |key| [ key, NATIVE_EQUIVALENTS[key] ] if NATIVE_EQUIVALENTS[key] }
            .group_by(&:last).transform_values { |pairs| pairs.map(&:first) }
          return "" if grouped.empty?

          " " + grouped.map { |option, keys| "Use #{option} for #{keys.to_sentence}." }.join(" ")
        end

        def parse_format(format)
          normalized = (format || :html).to_sym

          unless VALID_FORMATS.include?(normalized)
            raise QueryError, "Invalid highlight format: #{format.inspect}. Use :html or :text."
          end

          normalized
        end

        def parse_markers(markers)
          markers ||= [ DEFAULT_OPEN, DEFAULT_CLOSE ]

          unless markers.is_a?(Array) && markers.size == 2
            raise QueryError, "markers must be an Array of two strings, got #{markers.inspect}"
          end

          @open_marker, @close_marker = markers.map { |marker| validate_marker(marker) }
        end

        def validate_marker(marker)
          pattern = html? ? HTML_MARKER : TEXT_MARKER

          unless marker.is_a?(String) && pattern.match?(marker)
            raise QueryError, marker_error(marker)
          end

          # Frozen, so a validated marker cannot become a payload later.
          marker.frozen? ? marker : marker.dup.freeze
        end

        def marker_error(marker)
          if html?
            "Invalid highlight marker: #{marker.inspect}. HTML markers must be tags of " \
              "#{SAFE_TAGS.join(', ')} with optional class or id attributes."
          else
            "Invalid highlight marker: #{marker.inspect}. Text markers must be at most 32 " \
              "characters and must not contain quotes or backslashes."
          end
        end

        def parse_snippet(value)
          case value
          when true
            # :default leaves the store to pick its own unit and size.
            @snippet_unit = :default
            @snippet_value = nil
          when Integer
            raise QueryError, "Use { words: N } or { characters: N } for snippet size"
          when Hash
            value = value.symbolize_keys
            if value[:words]
              @snippet_unit = :words
              @snippet_value = validate_snippet_size(value[:words])
            elsif value[:characters]
              @snippet_unit = :characters
              @snippet_value = validate_snippet_size(value[:characters])
            else
              raise QueryError, "Snippet requires :words or :characters key"
            end
          when false, nil
            @snippet_unit = nil
            @snippet_value = nil
          else
            raise QueryError, "Invalid snippet option: #{value.inspect}"
          end
        end

        def validate_snippet_size(size)
          unless size.is_a?(Integer) && size.positive? && size <= MAX_SNIPPET_SIZE
            raise QueryError,
              "Snippet size must be an Integer between 1 and #{MAX_SNIPPET_SIZE}, got #{size.inspect}"
          end

          size
        end
    end
  end
end
