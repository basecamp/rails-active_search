# frozen_string_literal: true

module ActiveSearch
  # Adds the +has_search+ declaration to Active Record models.
  #
  # The engine includes Indexable in ActiveRecord::Base. A model receives Model's search,
  # indexing, callback, and result methods only after it calls +has_search+.
  #
  #   class Article < ApplicationRecord
  #     has_search
  #   end
  module Indexable
    extend ActiveSupport::Concern

    class_methods do
      # Connects this model to an index declared with ActiveSearch.define_index.
      #
      #   has_search                                          # infers :articles from table_name
      #   has_search index: :records                          # explicit index name
      #   has_search index: :records, serializer: :to_search_doc
      #   has_search index: :messages, default: true
      #   has_search scope: -> { where(removed_at: nil) }
      #
      # ==== Options
      #
      # * +:index+ - Selects a defined index; defaults to the model's table name.
      # * +:default+ - Selects this index for Model.search when the model declares several indexes;
      #   defaults to false. Only one declaration may be the default.
      # * +:async+ - Enqueues ReindexJob and RemoveJob when true, or writes inline when false;
      #   defaults to true.
      # * +:serializer+ - Uses a record method name or callable to produce the document Hash. By
      #   default, each declared field is read from a method of the same name.
      # * +:if+ - Adds a record when the guard is truthy and applies the same guard on destroy.
      # * +:unless+ - Adds a record when the guard is falsey and applies the same guard on destroy.
      # * +:add_if+ - Replaces +:if+ for additions without replacing +:unless+.
      # * +:add_unless+ - Replaces +:unless+ for additions without replacing +:if+.
      # * +:remove_if+ - Permits removals when truthy and replaces +:if+ for removals.
      # * +:remove_unless+ - Permits removals when falsey and replaces +:unless+ for removals.
      # * +:scope+ - Uses a lambda that returns the ActiveRecord::Relation through which matching
      #   records are loaded.
      # * +:reindex_on_touch+ - Reindexes this declaration after +touch+ when true; defaults to
      #   false.
      #
      # A guard accepts a Symbol called on the record, a Proc called with the record, or a literal
      # value. Shared guards decide additions and destroyed-record removals. A live record that no
      # longer passes its addition guards is removed unless its removal guards prevent that.
      #
      # Raises ConfigurationError when installation would replace a model method, when more than one
      # index is marked as default, or later when an invalid serializer or scope is used.
      def has_search(index: nil, default: false, async: true, serializer: nil,
                     if: nil, unless: nil, add_if: nil, add_unless: nil,
                     remove_if: nil, remove_unless: nil, scope: nil,
                     reindex_on_touch: false)
        _install_active_search unless _active_search_installed?

        index_name = (index || self.table_name).to_sym

        # The reflection reads guards by key presence, so compact keeps a guard nobody gave out of
        # the Hash and lets a literal false mean "never" rather than "no guard".
        reflection = IndexReflection.new(
          index_name,
          {
            async: async,
            serializer: serializer,
            if: binding.local_variable_get(:if),
            unless: binding.local_variable_get(:unless),
            add_if: add_if,
            add_unless: add_unless,
            remove_if: remove_if,
            remove_unless: remove_unless,
            scope: scope,
            reindex_on_touch: reindex_on_touch
          }.compact
        )

        self._index_reflections = _index_reflections.merge(index_name => reflection)

        if default
          if _default_search_index && _default_search_index != index_name
            raise ConfigurationError,
              "#{self} already has :#{_default_search_index} as its default search index. " \
              "Only one can be marked default: true."
          end
          self._default_search_index = index_name
        end
      end

      private
        # Idempotent, so a reload re-installing is not a conflict with itself.
        def _active_search_installed?
          include?(Model)
        end

        def _install_active_search
          _refuse_conflicting_methods!
          include Model
        end

        # A method on the class wins over one from an included module, so installing over a
        # conflict would silently leave the model calling its own.
        def _refuse_conflicting_methods!
          Model::ClassMethods.instance_methods.each do |method|
            _refuse_conflict!(method, owner_of_class_method(method), "class method")
          end

          Model.public_instance_methods.each do |method|
            _refuse_conflict!(method, owner_of_instance_method(method), "instance method")
          end
        end

        def _refuse_conflict!(method, owner, kind)
          return if owner.nil? || Model.installed?(owner)

          raise ConfigurationError,
            "The #{kind} #{method} on #{self} is defined by #{owner}. ActiveSearch will not " \
            "install over it. Rename yours, and delegate to ActiveSearch's if you still need it."
        end

        # Nil when nothing defines the method, and also when respond_to? reports a
        # method_missing responder, which has no method to own.
        def owner_of_class_method(method)
          singleton_class.instance_method(method).owner if respond_to?(method)
        rescue NameError
          nil
        end

        def owner_of_instance_method(method)
          instance_method(method).owner if method_defined?(method) || private_method_defined?(method)
        end
    end
  end
end
