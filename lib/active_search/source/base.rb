module ActiveSearch
  module Source # :nodoc: all
    class Base
      # What define_index accepts as a custom source. Answering these names is all that is checked.
      CUSTOM_CONTRACT = %i[ records_for id_for ].freeze

      attr_reader :name, :index_name, :id_column, :identity_fields, :storage_key_columns

      # +name+ names the document's id column, so it is schema. +index_name+ keys the model's
      # has_search declaration.
      def initialize(name:, index_name: nil)
        @name = name
        @index_name = index_name || name
        @id_column = :"#{name}_id"
        @identity_fields = [].freeze
        @storage_key_columns = [ @id_column ].freeze
      end

      def records_for(ids)
        raise NotImplementedError, "#{self.class} must implement #records_for"
      end

      # The relation records load through. The only part of a source that varies per query.
      def scope
        raise NotImplementedError, "#{self.class} must implement #scope"
      end

      # A copy loading through +relation+, merged with Rails' own semantics.
      def with_scope(relation)
        raise QueryError, "#{self.class.name.demodulize} does not take a scope"
      end

      def id_for(record)
        raise NotImplementedError, "#{self.class} must implement #id_for"
      end

      # Returns identity metadata to merge into the document data.
      def identity_attributes_for(record)
        {}
      end

      # Narrows a search to one model. A filter, not a scope: #scope decides what loads.
      def type_filter_for(model_class)
        {}
      end

      def storage_key(document_id)
        { id_column => document_id }
      end

      def build_document_id(stored)
        stored[id_column].to_s
      end
    end
  end
end
