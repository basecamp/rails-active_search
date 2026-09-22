module ActiveSearch
  module StoreAdapters
    class Database
      # The Ruby for a migration that builds a database-backed index. Explicit DDL rather than a call
      # that re-reads the declaration, because a migration must mean the same thing in a year. Only
      # for the adapter this application is connected to; a branch for the other two never runs.
      class MigrationSource # :nodoc:
        DOUBLE_PRECISION = 53

        # create_table takes a bare symbol here, so a schema qualifier, a hyphen or a space is
        # interpolated into Ruby that will not run.
        BARE_TABLE_NAME = /\A[a-z_][a-z0-9_]*\z/

        COLUMN_TYPES = { text: :text, string: :string, integer: :bigint, float: :float,
                         boolean: :boolean, date: :date, datetime: :datetime }.freeze

        def initialize(index, table_name, store)
          @index = index
          @table_name = table_name
          @store = store
          @definition = index.definition
          @source = index.source
        end

        attr_reader :table_name

        def class_name
          "Create#{table_name.camelize}"
        end

        def file_name
          "create_#{table_name}"
        end

        def refusal
          if !BARE_TABLE_NAME.match?(table_name)
            "#{table_name} cannot be written as a bare table name. Set self.table_name to lowercase " \
              "letters, digits and underscores, or write this migration by hand."
          elsif !@source.is_a?(ActiveSearch::Source::Base)
            "#{@index.index_name} has a custom source, which cannot name its key columns. " \
              "Write this migration by hand."
          end
        end

        # Composed here rather than by the generator, whose template renders only this. A Rails
        # generator reaches t.type and add_index, which cannot say FTS5 virtual table, FULLTEXT
        # index or tsvector column.
        def to_ruby
          <<~RUBY
            class #{class_name} < ActiveRecord::Migration[#{ActiveRecord::Migration.current_version}]
              def change
                create_table :#{table_name} do |t|
            #{column_lines.join("\n").indent(6)}
                end
                add_index :#{table_name}, #{key_index}, unique: true
            #{@store.search_index_lines(table_name, text_names).join("\n")}
              end
            end
          RUBY
        end

        private
          def text_names
            @definition.fields.select(&:searchable?).map { |field| field.name.to_s }
          end

          # Bare statements; to_ruby indents them, so the shape of the migration is in one place.
          def column_lines
            keys = @source.storage_key_columns
            keys.map { |column| "t.string :#{column}, null: false" } + field_columns(keys.map(&:to_sym))
          end

          # A Ruby Float is a double, and MySQL reads a bare t.float as single precision. The other
          # two give a double either way.
          def column_options(field)
            ", limit: #{DOUBLE_PRECISION}" if field.type == :float
          end

          def key_index
            columns = @source.storage_key_columns
            columns.one? ? ":#{columns.first}" : "[ #{columns.map { |c| ":#{c}" }.join(", ")} ]"
          end

          def field_columns(keys)
            @store.table_fields(@definition).reject { |field| keys.include?(field.name) }.map do |field|
              "t.#{column_type(field)} :#{field.name}#{column_options(field)}"
            end
          end

          # A collection is one JSON column, which the store names: jsonb on PostgreSQL, json elsewhere.
          def column_type(field)
            field.multiple? ? @store.collection_native_type : COLUMN_TYPES.fetch(field.type)
          end
      end
    end
  end
end
