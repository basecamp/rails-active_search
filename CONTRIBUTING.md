# Contributing

This is alpha software. There is no backward-compatibility obligation yet: delete old
code rather than deprecating it.

## Running the tests

```bash
bin/setup
bin/rails test                             # Default adapter (SQLite FTS5)
SEARCH_ADAPTER=postgresql bin/rails test   # A specific adapter
```

Backends that need a server are provided by `docker-compose.yml`:

```bash
docker compose up -d elasticsearch
SEARCH_ADAPTER=elasticsearch bin/rails test
```

Elasticsearch 7 and 8 run against pinned client gems in `gemfiles/`.

## Architecture

- **Index declarations** (`test/dummy/config/search.rb`) — `ActiveSearch.define_index`
  blocks declaring `text`, `string`, `integer`, `float`, `date`, `datetime`, and
  `boolean` fields
- **Adapters** (`lib/active_search/store_adapters/`) — one per backend, composed from
  mixins: `QueryBuilding` converts a QueryContext to a native query, `ResponseParsing`
  maps the backend response to the standard format, `Highlighting` generates snippets
- **Query** (`lib/active_search/query.rb`) — immutable query builder; every chained
  call returns a new object
- **QueryContext** — immutable state container passed through the query chain

## Style

- Avoid early returns
- Comments are one line, two only when one genuinely will not carry it. Comment the
  surprise, not the code: a comment earns its place when it states a constraint or a
  reason the code cannot show
- Private methods indented, no blank line after `private`:

```ruby
private
  def some_method
  end
```

Run `bin/rubocop` before submitting.
