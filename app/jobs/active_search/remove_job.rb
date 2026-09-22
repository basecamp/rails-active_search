module ActiveSearch
  # Removes one document by identifier from an index on the +active_search+ queue.
  #
  # Enqueue with an index name, document identifier, and optional routing value:
  #
  #   ActiveSearch::RemoveJob.perform_later(:articles, article.id)
  #
  # The job does not load the source record, so it still removes the document after the record is
  # gone. Removing a document that is already absent follows the configured adapter's delete behavior.
  class RemoveJob < BaseJob
    # Removes +id+ from +index_name+.
    #
    # ==== Options
    #
    # * +:routing+ - Supplies the routing value required by a routed index.
    def perform(index_name, id, routing: nil)
      ActiveSearch.index(index_name).remove_by_id(id, routing: routing)
    end
  end
end
