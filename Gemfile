source "https://rubygems.org"

# Specify your gem's dependencies in rails-active_search.gemspec.
gemspec

gem "puma"

gem "sqlite3"

gem "propshaft"

# Elasticsearch adapter. The matrix runs 7, 8 and 9 because a client only talks to its own
# major: a 9 client is refused by an 8 server, so a version is only supported if it is tested.
case ENV["ELASTICSEARCH_VERSION"]
when "7" then gem "elasticsearch", "~> 7.0"
when "8" then gem "elasticsearch", "~> 8.0"
else          gem "elasticsearch", "~> 9.0"
end

# Meilisearch adapter
gem "meilisearch"

# Typesense adapter
gem "typesense"

# OpenSearch adapter
gem "opensearch-ruby"

# Solr adapter. rsolr opens a connection per request without a persistent Faraday adapter.
gem "rsolr"
gem "faraday-net_http_persistent"

# Redis Search adapter
gem "redis"

# MySQL adapter (for testing)
gem "mysql2"

# PostgreSQL adapter (for testing)
gem "pg"

# Profiling
gem "stackprof"

# Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
gem "rubocop-rails-omakase", require: false
