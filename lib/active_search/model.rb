module ActiveSearch
  # Adds search and indexing behavior to a model that declares +has_search+.
  #
  # Model installs the class methods +search+, +suppress_indexing+, and +indexing_suppressed?+; the
  # instance methods +reindex+ and Resultable#hit; index reflections; and callbacks that update each
  # declared index after commits.
  module Model
    extend ActiveSupport::Concern

    # Methods available on a search result. A custom source's own objects include this themselves.
    include Resultable

    included do
      # Only the writers go private: class_attribute builds its instance reader on the class reader.
      class_attribute :_index_reflections, instance_writer: false, default: {}
      class_attribute :_default_search_index, instance_writer: false, default: nil
      private_class_method :_index_reflections=, :_default_search_index=

      [ :after_save, :after_touch, :after_commit ].each do |callback|
        send(callback, IndexingCallbacks)
      end
    end

    class_methods do
      # Starts a model-scoped search and returns a chainable Query.
      #
      #   Article.search("rails")
      #   Article.search("rails", index: :records)
      #   Article.search("rails", scope: Article.preload(:comments))
      #
      # ==== Options
      #
      # * +:index+ - Selects one of the model's +has_search+ declarations; defaults to the declared
      #   default or the first declaration.
      # * +:scope+ - Merges an ActiveRecord::Relation into the relation used to load matching records.
      # * Other keyword options are passed to Query#search.
      #
      # A polymorphic source adds a model type constraint that later filters can narrow but cannot
      # broaden. Raises ConfigurationError when the model has no selected index and QueryError when
      # the scope does not load this model.
      def search(query = nil, index: nil, scope: nil, **kwargs, &blk)
        idx_name = index ? index.to_sym : _active_search_default_index
        ref = _index_reflections[idx_name]
        raise ConfigurationError, "#{self} has no search index :#{idx_name}" unless ref
        idx = ref.index

        relation = idx.search(query, **kwargs, &blk)
        # A relation becomes a source here, so the query layer never sees one.
        relation = relation.with_source(idx.source.with_scope(scope)) if scope

        # Protected, so a caller naming the same field narrows this rather than replacing it.
        type_filter = idx.source.type_filter_for(self) if idx.source.respond_to?(:type_filter_for)
        relation = relation.protect(type_filter) if type_filter.present?

        relation
      end

      # Disables automatic indexing of saves for the duration of the block and returns its value.
      #
      #   articles = Article.where(status: :draft).to_a
      #   Article.suppress_indexing do
      #     articles.each { |article| article.update!(status: :archived) }
      #   end
      #   articles.each(&:reindex)
      #
      # Suppression is local to the execution context and model class, includes STI subclasses, and
      # is restored when the block returns or raises. Destroying a record still removes its document.
      # Methods that skip callbacks, such as +update_all+, do not invoke indexing in either state.
      def suppress_indexing
        original = indexing_suppressed?
        ActiveSupport::IsolatedExecutionState[_active_search_suppression_key] = true
        yield
      ensure
        ActiveSupport::IsolatedExecutionState[_active_search_suppression_key] = original
      end

      # Returns true when Model.suppress_indexing is active for this model or an STI superclass.
      def indexing_suppressed?
        ActiveSupport::IsolatedExecutionState[_active_search_suppression_key] ||
          (superclass.respond_to?(:indexing_suppressed?) && superclass.indexing_suppressed?)
      end

      private
        def _active_search_suppression_key
          :"active_search_indexing_suppressed_#{name || object_id}"
        end

        def _active_search_default_index
          _default_search_index || _index_reflections.keys.first
        end
    end

    # Whether a method's owner is one of ours, and so not a conflict. A method rather than a
    # constant: this module is an ancestor of every indexed model, so a constant here would shadow.
    def self.installed?(mod) # :nodoc:
      [ Model, ClassMethods, Resultable ].include?(mod)
    end

    # Re-evaluates the record against every declared index.
    #
    #   Card.find_each(&:reindex)
    #
    # Each declaration follows its +async:+ setting. A record that passes the add guards is written.
    # One that fails them is removed, unless a remove guard prevents that, in which case its document
    # is left unchanged. ActiveSearch::Index#add bypasses these guards.
    def reindex
      _index_reflections.each_value { |reflection| reflection.update(self) }
    end
  end
end
