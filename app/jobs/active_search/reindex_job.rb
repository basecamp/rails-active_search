module ActiveSearch
  # Re-evaluates one record's guards and updates one declared index on the +active_search+ queue.
  #
  # Enqueue with an index name and an Active Record object:
  #
  #   ActiveSearch::ReindexJob.perform_later(:articles, article)
  #
  # The record is serialized through GlobalID. If it is gone before execution, the job is discarded;
  # its destroy callback has already enqueued RemoveJob. Other deserialization errors are raised.
  class ReindexJob < BaseJob
    # Applies the current guards to +record+ and writes or removes its document. A record that passes
    # neither the add guards nor the remove guards leaves its document unchanged.
    #
    # Nothing is done when the record no longer declares +index_name+.
    def perform(index_name, record)
      record.class._index_reflections[index_name.to_sym]&.update_now(record)
    end
  end
end
