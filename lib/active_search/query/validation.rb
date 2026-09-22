module ActiveSearch
  class Query
    module Validation # :nodoc: all
      # Each segment separately, so a name is rejected rather than matched loosely.
      SEGMENT_PATTERN = /\A[A-Za-z_][A-Za-z0-9_]*\z/

      private
        def validate_search_fields!(fields)
          fields.each { |field| validate_search_field!(field) }
        end

        def validate_search_field!(field)
          name = field.to_s
          base, suffix = name.split(".", 2)

          if !SEGMENT_PATTERN.match?(base) || (suffix && !SEGMENT_PATTERN.match?(suffix))
            raise QueryError, "Invalid search field #{field.inspect}. #{searchable_description}"
          elsif suffix
            validate_search_subfield!(field, base)
          elsif definition.searchable?(base)
            true
          elsif definition.string_field?(base)
            validate_string_field_search!(field, base)
          else
            raise QueryError, "Invalid search field #{field.inspect}. #{searchable_description}"
          end
        end

        # A subfield is a validation-only passthrough: ActiveSearch does not own index mappings.
        def validate_search_subfield!(field, base)
          unless definition.searchable?(base)
            raise QueryError,
              "Invalid search field #{field.inspect}. A subfield's base must be a declared text field. " \
              "#{searchable_description}"
          end

          unless store.capabilities.supports_search_subfields?
            raise UnsupportedOperationError,
              "#{store_description} does not support search subfields, so #{field.inspect} cannot be selected"
          end
        end

        # A string-declared field is never part of default search and never highlightable. Searching
        # one runs the store's text query over it rather than matching exactly; filter is exact.
        def validate_string_field_search!(field, base)
          unless store.capabilities.supports_search_string_fields?
            raise UnsupportedOperationError,
              "#{store_description} does not support searching a string field, so #{field.inspect} " \
              "cannot be selected. Use filter for exact matching."
          end
        end

        def searchable_description
          "Searchable fields: #{definition.search_fields.join(', ')}"
        end

        def store_description
          store.class.name.demodulize
        end

        def validate_highlight_capabilities!(opts)
          caps = store.capabilities
          store_name = store.class.name.demodulize

          unless caps.supports_highlighting?
            raise UnsupportedOperationError, "#{store_name} does not support highlighting"
          end

          if opts.multiple_marker_variants? && !caps.supports_highlight_per_field_markers?
            raise UnsupportedOperationError, "#{store_name} does not support per-field highlight markers"
          end

          if opts.multiple_snippet_variants? && !caps.supports_highlight_per_field_snippets?
            raise UnsupportedOperationError, "#{store_name} does not support per-field snippet options"
          end

          usable = Highlighting::FieldOptions::UNITS.select { |unit| caps.supports_snippet_unit?(unit) }

          Highlighting::FieldOptions::UNITS.each do |unit|
            next unless opts.any_snippet_with_unit?(unit) && !caps.supports_snippet_unit?(unit)

            raise UnsupportedOperationError, if usable.empty?
              "#{store_name} does not support snippets"
            else
              "#{store_name} does not support #{unit}-based snippets. Use { #{usable.first}: N } instead."
            end
          end

          if opts.any_snippet_with_unit?(:default) && usable.empty?
            raise UnsupportedOperationError, "#{store_name} does not support snippets"
          end
        end

        # The search-field policy minus the string-only allowance: there is nothing analyzed to mark.
        def validate_highlight_fields!(opts)
          if opts.specific_fields?
            opts.requested_fields.each do |field|
              name = field.to_s
              base, suffix = name.split(".", 2)

              if !SEGMENT_PATTERN.match?(base) || (suffix && !SEGMENT_PATTERN.match?(suffix))
                raise QueryError, "Field '#{field}' is not highlightable. #{highlightable_description}"
              elsif !definition.searchable?(base)
                raise QueryError, "Field '#{field}' is not highlightable. #{highlightable_description}"
              elsif suffix && !store.capabilities.supports_search_subfields?
                raise UnsupportedOperationError,
                  "#{store_description} does not support search subfields, so '#{field}' cannot be highlighted"
              end
            end
          end
        end

        def highlightable_description
          "Highlightable fields: #{definition.search_fields.join(', ')}"
        end

        def validate_unwindowed!
          set = []
          set << "limit" unless query_context.limit_unset?
          set << "offset" unless query_context.offset.nil?
          return if set.empty?

          raise QueryError,
            "page sets its own limit and offset, so it cannot follow #{set.join(" and ")}. " \
            "Size a page with per_page: instead."
        end

        def validate_filterable!(field_names)
          field_names.each do |name|
            unless definition.filterable?(name)
              available = definition.filter_fields.keys.join(", ")
              raise QueryError, "Field '#{name}' is not filterable. Filterable fields: #{available}"
            end
          end
        end

        def validate_sortable!(value)
          return if value == Score

          field_name = case value
          when Symbol then value
          when String then value.to_sym
          when Hash then value.keys.first
          end

          # Refused here rather than passed through, where it would crash inside an adapter.
          if field_name.nil?
            raise QueryError, "sort takes a field name or {field: :direction}, got #{value.inspect}"
          end

          unless definition.filterable?(field_name)
            available = definition.filter_fields.keys.join(", ")
            raise QueryError, "Field '#{field_name}' is not sortable. Sortable fields: #{available}"
          end

          # Elasticsearch and Solr would order by the minimum ascending and the maximum descending;
          # the database adapters would order by the JSON container itself.
          if definition[field_name]&.multiple?
            raise QueryError,
              "Field '#{field_name}' holds many values and cannot be sorted on. Stores disagree " \
              "about which element would order the document."
          end
        end

        def validate_hit_fields!(fields)
          fields.each do |field|
            unless definition[field]
              raise QueryError, "Unknown field '#{field}'. Available fields: #{definition.field_names.join(", ")}"
            end
          end
        end

        def validate_missing_filters!(field)
          unless store.capabilities.supports_missing_filters?
            raise UnsupportedOperationError,
              "#{store.class.name.demodulize} does not support missing-value filters on '#{field}'"
          end
        end

        # A range over a collection asks whether any element falls inside it.
        def validate_collection_range!(name, value)
          return unless value.is_a?(Range) && definition[name]&.multiple?

          unless store.capabilities.supports_collection_ranges?
            raise UnsupportedOperationError,
              "#{store.class.name.demodulize} does not support a range on '#{name}', which holds " \
              "many values. Name the values instead."
          end
        end

        def validate_operator!(operator)
          caps = store.capabilities
          store_name = store.class.name.demodulize

          if operator && !caps.supports_operator?
            raise UnsupportedOperationError, "#{store_name} does not support operator option"
          end
        end
    end
  end
end
