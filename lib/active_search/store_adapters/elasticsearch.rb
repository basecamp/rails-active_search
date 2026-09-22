require "elasticsearch"

module ActiveSearch
  module StoreAdapters
    # Store adapter for Elasticsearch, selected with <tt>adapter: elasticsearch</tt>.
    #
    # Uses the +elasticsearch+ gem. The gem's major version must match the server's: a 9 client is
    # refused by an 8 server.
    #
    # ==== Options
    #
    # * +:hosts+ - An Array of <tt>{ host:, port: }</tt> Hashes. Defaults to +localhost+ on port 9200.
    # * +:max_result_window+ - The store's largest <tt>offset + limit</tt>. Defaults to 10,000, the
    #   server's own default.
    #
    # <tt>bin/rails active_search:index:create</tt> creates the index from the declaration. Mappings
    # and analysis beyond that are set through the native client.
    class Elasticsearch < Elastic
      # :stopdoc:
      # Declared after the require so the constants exist: 7.x defines Elasticsearch::Transport's
      # error, 8/9 define Elastic::Transport's. Every transport failure descends from it.
      CLIENT_ERRORS = [
        defined?(::Elastic::Transport::Transport::Error) ? ::Elastic::Transport::Transport::Error : nil,
        defined?(::Elasticsearch::Transport::Transport::Error) ? ::Elasticsearch::Transport::Transport::Error : nil
      ].compact.freeze

      self.client_class = ::Elasticsearch::Client
      self.not_found_error = if legacy_elasticsearch?
        ::Elasticsearch::Transport::Transport::Errors::NotFound
      else
        ::Elastic::Transport::Transport::Errors::NotFound
      end
      self.default_port = 9200
    end
  end
end
