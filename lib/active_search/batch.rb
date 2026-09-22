module ActiveSearch
  # Buffers add and remove operations for an Index and writes them together on +flush+. How many
  # store requests a flush makes depends on the adapter.
  #
  # A failed flush keeps the buffer, so a caller can rescue and call +flush+ again. Replaying is
  # safe even after a partial write: adds are id-keyed upserts and removes are idempotent, so an
  # operation that already landed lands the same way twice.
  #
  # Usually built by Index#batch. A nil +max_size+ disables automatic flushing.
  class Batch
    attr_reader :index, :max_size # :nodoc:

    def initialize(index, max_size: 1000, **store_options) # :nodoc:
      @index = index
      @max_size = max_size
      @store_options = store_options
      @operations = []
    end

    # Buffers +record+'s document.
    #
    #   batch.add(article)
    #
    # The +has_search+ guards do not run, so this writes a record that a guarded save might remove.
    # Reaching +max_size+ flushes the batch.
    def add(record)
      @operations << [ :add, [ index.document_for(record), index.routing_for(record) ] ]
      flush if max_size && size >= max_size
    end

    # Buffers removal of +record+.
    #
    # The identifier and routing value come from the index source.
    def remove(record)
      remove_by_id(index.id_for(record), routing: index.routing_for(record))
    end

    # Buffers removal of +id+.
    #
    # ==== Options
    #
    # * +:routing+ - Supplies the routing value required by a routed index.
    def remove_by_id(id, routing: nil)
      @operations << [ :remove, [ id, routing ] ]
      flush if max_size && size >= max_size
    end

    # Writes all buffered operations and empties the buffer.
    #
    #   batch.flush
    #
    # An empty buffer does not contact the store. If the write raises, the buffer remains available
    # for another attempt.
    def flush
      return if @operations.empty?
      ActiveSupport::Notifications.instrument("flush_batch.active_search",
        index: index.name, operations: @operations.size, store_name: index.configured_store_name) do
        index.store.flush_batch(index, @operations, **@store_options)
      end
      @operations = []
    end

    # Returns the number of operations currently buffered.
    def size
      @operations.size
    end
  end
end
