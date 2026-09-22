require "opensearch-ruby"

module ActiveSearch
  module StoreAdapters
    # Store adapter for OpenSearch, selected with <tt>adapter: opensearch</tt>.
    #
    # Uses the +opensearch-ruby+ gem and takes the same options as Elasticsearch. Nothing else
    # differs from that adapter.
    class Opensearch < Elastic
      # :stopdoc:
      # Declared rather than inherited: Elastic's classes are Elasticsearch's, and
      # an OpenSearch transport failure is not one of them.
      CLIENT_ERRORS = [ ::OpenSearch::Transport::Transport::Error ].freeze

      self.client_class = ::OpenSearch::Client
      self.not_found_error = ::OpenSearch::Transport::Transport::Errors::NotFound
      self.default_port = 9200
    end
  end
end
