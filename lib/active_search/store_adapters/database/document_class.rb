module ActiveSearch
  module StoreAdapters
    class Database
      # Which ActiveRecord class and table a database-backed index writes through. The application
      # owns the class, so a connection, a scope and an inheritance column have somewhere to live.
      #
      # Not Model: a bare Model in an adapter resolves to ActiveSearch::Model first.
      module DocumentClass # :nodoc: all
        # The class has not been written yet, which the generator is about to fix. Separate from a
        # class that is there and wrong, because only this one may fall back to a conventional name.
        class Absent < ConfigurationError; end

        class << self
          def constant_name_for(index)
            index.document_class_name
          end

          # The generator writes the class, so it has to work out the table before one exists. An
          # application can only have renamed the table in a class it wrote, so no class means the
          # name Rails would have given it.
          def table_name_for(index)
            constant_name = constant_name_for(index)

            declared(index)&.table_name || projected(constant_name).table_name
          end

          # constant_name_for may return a string the application gave, and the generator writes
          # wherever it points. Resolved to a real path: a lexical check passes a symlink.
          def path_for(index)
            root = Rails.root.join("app/models")
            path = root.join("#{constant_name_for(index).underscore}.rb").cleanpath

            unless within?(root, path)
              raise ConfigurationError, "#{constant_name_for(index)} resolves outside app/models"
            end

            path
          end

          # An unwritten file has no real path, so the deepest existing parent is what to resolve.
          def within?(root, path)
            return path.to_s.start_with?("#{root}/") unless root.exist?

            existing = path
            existing = existing.parent until existing.exist? || existing.root?

            existing.realpath.to_s.start_with?("#{root.realpath}/") || existing.realpath == root.realpath
          rescue Errno::ENOENT
            false
          end

          # Rails derives a table name from the class name through a prefix, a suffix and
          # pluralize_table_names. A class answering to the name gives the table without repeating
          # those rules.
          def projected(constant_name)
            Class.new(ApplicationRecord) { define_singleton_method(:name) { constant_name } }
          end

          def declared(index)
            klass = constant_name_for(index).safe_constantize

            klass if klass.is_a?(Class) && klass < ActiveRecord::Base && !klass.abstract_class?
          end

          def for(index)
            constant_name = constant_name_for(index)
            klass = constant_name.safe_constantize

            if klass.nil?
              raise Absent,
                "#{constant_name} does not exist. " \
                "Run rails generate active_search:document #{index.name}."
            elsif klass.is_a?(Class) && klass < ActiveRecord::Base && !klass.abstract_class?
              klass
            else
              raise ConfigurationError,
                "#{constant_name} must be a concrete ActiveRecord model, not #{klass.class}."
            end
          end
        end
      end
    end
  end
end
