module ActiveSearch
  # A callback object, so an indexed model gains none of these as methods of its own.
  #
  # Not under Model, an ancestor of every indexed model: a constant there is what a bare one in a
  # model body would find.
  class IndexingCallbacks # :nodoc: all
    # Intent recorded per transaction rather than as one value, so a rollback drops only its own
    # entry, the commit writes what survived, and nested savepoints can unwind in any order.
    INTENTS = :@_active_search_intents

    # Active Record rolls back the database, never the instance's attributes, so after a savepoint
    # rollback the object is ahead of the row it mirrors. A surviving write must not serialize that.
    STALE = :@_active_search_stale

    class << self
      def after_save(record)
        record_intent record, :every_index
      end

      def after_touch(record)
        record_intent record, :indexes_that_asked if asked(record).any?
      end

      def after_commit(record)
        intents = record.instance_variable_get(INTENTS)
        # Cleared before the write, so a write that raises cannot leave intent for the next operation.
        record.instance_variable_set(INTENTS, nil)
        intent = effective_intent(intents)
        write(record, intent) if record.destroyed? || intent
      end

      private
        # A save covers every index, so a touch never narrows one already recorded.
        def record_intent(record, cover)
          unless record.class.indexing_suppressed?
            transaction = record.class.connection.current_transaction
            # Keyed by object_id, not the transaction itself, so an entry nobody clears cannot keep
            # the whole transaction and its records alive.
            key = transaction.object_id
            intents = record.instance_variable_get(INTENTS) || record.instance_variable_set(INTENTS, {})
            register_cleanup(transaction, intents, key, record) unless intents.key?(key)
            intents[key] = cover if intents[key].nil? || cover == :every_index
          end
        end

        # Drops the entry however the transaction ends, so the map cannot grow one key per
        # transaction the record takes part in.
        def register_cleanup(transaction, intents, key, record)
          transaction.after_commit { intents.delete(key) }
          transaction.after_rollback do
            intents.delete(key)
            record.instance_variable_set(STALE, true)
          end
        end

        def effective_intent(intents)
          if intents.nil? || intents.empty?
            nil
          elsif intents.value?(:every_index)
            :every_index
          else
            :indexes_that_asked
          end
        end

        def write(record, intent)
          refresh_rolled_back(record)
          if record.destroyed? || intent == :every_index
            record.reindex
          else
            asked(record).each_value { |reflection| reflection.update(record) }
          end
        end

        def asked(record)
          record._index_reflections.select { |_, reflection| reflection.reindex_on_touch? }
        end

        def refresh_rolled_back(record)
          if record.instance_variable_get(STALE)
            record.instance_variable_set(STALE, nil)
            record.reload unless record.destroyed?
          end
        end
    end
  end
end
