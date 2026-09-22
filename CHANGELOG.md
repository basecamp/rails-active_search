# Changelog

## 0.1.0

Initial release. Active Search provides a common interface for full-text search of
Active Record models across multiple backends: SQLite FTS5, PostgreSQL tsvector,
MySQL FULLTEXT, Elasticsearch, OpenSearch, Solr, Meilisearch, Typesense, Manticore,
and Redis Search. Indexes are declared in config/search.rb, queries are built with an immutable
chainable relation, and index writes run through Active Job. This is alpha software:
the API is not fixed and may change incompatibly between releases.
