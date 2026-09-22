module ActiveSearch
  module StoreAdapters
    # Store adapter for MySQL FULLTEXT, selected with <tt>adapter: mysql</tt>.
    #
    # Searches the application database through Active Record, so it takes no connection options.
    # Text and filter fields alike are columns on the document table.
    #
    # MATCH names exactly one index's whole column list, so a search with <tt>fields:</tt> needs its
    # own FULLTEXT index over exactly those columns. The generated migration writes one over all of
    # them.
    class Mysql < Database
      # :stopdoc:
      extend ActiveSupport::Autoload

      eager_autoload do
        autoload :QueryBuilding
      end

      include QueryBuilding

      # One index over every text column. MATCH must name exactly one index's whole column list, so
      # this serves a search over all of them and nothing else; subset_note says so in the migration.
      def search_index_lines(table_name, text_names)
        [ "", "    add_index :#{table_name}, #{text_names.map(&:to_sym).inspect}, type: :fulltext" ] +
          subset_note(text_names)
      end

      def subset_note(text_names) # :nodoc:
        if text_names.one?
          []
        else
          [ "",
            "    # This serves a search over all of #{text_names.join(", ")}. MySQL matches a FULLTEXT",
            "    # index by its whole column list, so searching a subset needs its own index." ]
        end
      end

      # A bare FLOAT is 24-bit here and a DOUBLE 53-bit, and both answer :float.
      def float_bits
        53
      end

      def search_native_type
        "fulltext"
      end

      # Searchable only where one FULLTEXT index covers the whole declared text set. Separate
      # indexes on each column serve no search over all of them.
      def observe_tables(index, table, connection)
        declared = index.definition.search_fields.map(&:to_s).sort
        covered = connection.indexes(table)
          .any? { |i| i.type == :fulltext && i.columns.sort == declared }

        columns_in(connection, table, role: :filterable) +
          (covered ? declared : []).map do |name|
            Schema::Observation.new(name: name, role: :searchable, native_type: "fulltext", location: table)
          end
      end

      def write(index, document, routing: nil)
        key = index.source.storage_key(document.id)
        # Text and filter fields are both columns here, and FULLTEXT reads the text ones in place.
        columns = document.writable_field_names - key.keys

        model_for(index, routing: routing).upsert(key.merge(replacement_attributes(document, columns)))
      end

      # collection_ranges keeps its false default, and there is no collection_range_sql to go with
      # it: JSON_TABLE is the only way to unroll a collection here, and it cannot correlate to an
      # outer column inside EXISTS.
      def capabilities
        @capabilities ||= Capabilities.new(
          # By writing a migration, which is how a table in the application's own schema is built.
          index_creation: true,
          highlighting: false,
          highlight_snippet_units: [],
          highlight_per_field_markers: false,
          highlight_per_field_snippets: false,
          operator: false,
          # Nothing caps a database page: the store returns and materializes whatever LIMIT asks.
          max_result_window: options.fetch(:max_result_window, 10_000)
        )
      end
    end
  end
end
