module ActiveSearch
  # Raised as the base class for every ActiveSearch error.
  class Error < StandardError; end

  # Raised when a query has invalid values or cannot be represented safely.
  class QueryError < Error; end
  # Raised when the configured store does not support a requested query operation.
  class UnsupportedOperationError < QueryError; end
  # Raised when a query's limit and offset reach past the configured store's result window, from
  # Query#page or from Query#results with an explicit limit or offset.
  class ResultWindowExceeded < QueryError; end

  # Raised when a value cannot be written as its declared field type.
  class DocumentError < Error; end
  # Raised when a store schema would discard every searchable field from a document.
  class UnsearchableWriteError < Error; end
  # Raised when an index, model, store, or option is configured incorrectly.
  class ConfigurationError < Error; end
  # Raised when an adapter's client reports a backend failure.
  class AdapterError < Error; end
  # Raised when part of a multi-document write fails.
  class PartialWriteError < AdapterError; end

  module Type
    # Raised by a field type and always converted by whoever asked it to cast: DocumentError for a
    # document value, QueryError for a filter value.
    class Invalid < Error; end # :nodoc:
  end
end
