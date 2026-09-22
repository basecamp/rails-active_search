# Active Search

Active Search implements search for Rails. It provides a common interface for searching Active Record
models across multiple search backends.

This is **alpha** software. The API is not fixed and may have backward incompatible changes in future.

**Supported adapters:**
- **Database:** SQLite FTS5, PostgreSQL tsvector, MySQL FULLTEXT
- **Search engines:** Elasticsearch, OpenSearch, Solr, Meilisearch, Typesense, Manticore, Redis Search

## Contents

- [Installation](#installation)
- [Quick start](#quick-start)
- [Configuration](#configuration)
  - [Named adapters](#named-adapters)
  - [Index prefix](#index-prefix)
  - [Database adapters](#database-adapters)
  - [Search engine adapters](#search-engine-adapters)
- [Indexing](#indexing)
  - [Index definitions](#index-definitions)
  - [Collection fields](#collection-fields)
  - [Polymorphic indexes](#polymorphic-indexes)
  - [Models](#models)
  - [Manual indexing](#manual-indexing)
- [Searching](#searching)
  - [Queries](#queries)
  - [Filtering](#filtering)
  - [Highlighting](#highlighting)
  - [Results](#results)
  - [Loading records](#loading-records)
  - [Routing](#routing)
  - [Native queries](#native-queries)
- [Adapters](#adapters)
  - [Capabilities](#capabilities)
  - [Documented divergences](#documented-divergences)
  - [Verified versions](#verified-versions)
  - [Custom adapters](#custom-adapters)
- [Commands](#commands)
- [Instrumentation](#instrumentation)
- [Limitations](#limitations)
- [License](#license)

## Installation

Add the gem:

```ruby
gem "rails-active_search"
```

For a search engine, add its client gem:

```ruby
gem "elasticsearch", "~> 8.0"  # match your server's major version
gem "opensearch-ruby"
gem "rsolr"                    # Solr
gem "meilisearch"
gem "typesense"
gem "redis"                    # Redis Search
# Manticore needs no gem
```

The Elasticsearch client must match the server's major version. See
[Verified versions](#verified-versions).

## Quick start

**1. Configure the adapter.** Create `config/search.yml`:

```yaml
test:
  adapter: sqlite

production:
  adapter: elasticsearch
  hosts:
    - host: search.example.com
      port: 9200
```

**2. Define an index.** Declare it in `config/search.rb`:

```ruby
ActiveSearch.define_index(:articles) do
  text :title
  text :content
  integer :account_id
  string :status
  datetime :published_at
  boolean :featured
end
```

**3. Connect the model.** Add `has_search`:

```ruby
class Article < ApplicationRecord
  has_search
end
```

See [Models](#models).

**4. Search.**

```ruby
results = Article.search("rails").results

results.each do |article|
  article.title      # the record
  article.hit.score
end
```

## Configuration

`config/search.yml` sets the adapter for each environment, as in the [Quick start](#quick-start).
The migrations and connection settings for each adapter follow.

### Named adapters

An environment can have several stores, one per key. Set `store_name:` on an index to use one of
them. Without it, the index uses `default`.

```yaml
production:
  default:
    adapter: elasticsearch
    hosts:
      - host: search.example.com
        port: 9200
  legacy:
    adapter: mysql
```

```ruby
ActiveSearch.define_index(:legacy_articles, store_name: :legacy) { ... }
```

### Index prefix

`index_prefix` is added to the front of every index name on that store. Use it when two
environments share one search engine. The install generator sets `development_` and `test_` for
the search engine adapters.

```yaml
development:
  adapter: elasticsearch
  index_prefix: development_
```

### Database adapters

A database adapter stores each index in a table with a column per filterable field and a full-text
index over the `text` fields (see [Index definitions](#index-definitions)). A `multiple:` field is a
JSON column, `jsonb` on PostgreSQL. The application owns the migration. The [document generator](#commands) writes it.

**SQLite** uses a table for the fields and an FTS5 virtual table for the text:

```ruby
class CreateArticleSearch < ActiveRecord::Migration[8.0]
  def change
    create_table :article_documents do |t|
      t.string :article_id, null: false
      t.integer :account_id
      t.string :status
    end
    add_index :article_documents, :article_id, unique: true
    create_virtual_table :article_documents_fts, :fts5, [:title, :content]
  end
end
```

FTS5 does not stem by default, so `company` does not find "companies". Add the `porter` tokenizer
to stem:

```ruby
create_virtual_table :article_documents_fts, :fts5,
  [ :title, :content, "tokenize='porter'" ]
```

**PostgreSQL** uses tsvector columns with GIN indexes:

```ruby
create_table :article_documents do |t|
  t.string :article_id, null: false
  t.text :title, :content
  t.tsvector :title_vector, :content_vector
  t.integer :account_id
end
add_index :article_documents, :title_vector, using: :gin
```

**MySQL** uses a FULLTEXT index:

```ruby
add_index :article_documents, [:title, :content], type: :fulltext
```

MySQL matches a FULLTEXT index by its whole column list. A search that names a subset of the
fields (see [Queries](#queries)) needs its own index over exactly those columns.

### Search engine adapters

Each adapter has its own connection settings:

```yaml
# Elasticsearch or OpenSearch
production:
  adapter: elasticsearch
  hosts:
    - host: localhost
      port: 9200

# Meilisearch
production:
  adapter: meilisearch
  url: http://localhost:7700
  api_key: your_master_key

# Typesense
production:
  adapter: typesense
  nodes:
    - host: localhost
      port: 8108
      protocol: http
  api_key: your_api_key

# Solr
production:
  adapter: solr
  url: http://localhost:8983/solr

# Manticore
production:
  adapter: manticore
  host: localhost
  port: 9308

# Redis Search
production:
  adapter: redis_search
  host: localhost
  port: 6379
```

Then create each index. See [Commands](#commands).

The Elasticsearch and OpenSearch clients log to `Rails.logger`. Set
`config.active_search.logger` to send their logging elsewhere.

## Indexing

### Index definitions

Declare each index in `config/search.rb`. A `text` field is searched. The other types are filtered
and sorted, and a `string` field holds one exact value. Declare the type your application writes.
ActiveSearch casts each value to it when it builds a document.

```ruby
ActiveSearch.define_index(:articles) do
  text :title
  text :content
  string :status
  integer :account_id
  float :price
  boolean :featured
  datetime :published_at
  date :published_on
end
```

Each index loads its results through a source. By default that is the class named by the singular
of the index name. Set `source:` to name another class, or `polymorphic: true` to load
several. On a database adapter, set `document_class:` to use your own model for the index table
in place of the generated one.

```ruby
ActiveSearch.define_index(:articles) { ... }                              # Article
ActiveSearch.define_index(:namespaced_tests, source: "Article") { ... }   # Article
ActiveSearch.define_index(:records, polymorphic: true) { ... }            # several classes
ActiveSearch.define_index(:records, document_class: "Search::RecordDocument") { ... }
```

### Collection fields

Set `multiple: true` on an `integer`, `string` or `datetime` field to store a list of values:

```ruby
ActiveSearch.define_index(:topics) do
  text :subject
  integer :folder_ids, multiple: true
  string :labels, multiple: true
end
```

A filter matches documents whose list contains any of the given values, the same as `IN` on a
single value:

```ruby
# topics in folder 4, folder 9, or both
ActiveSearch.index(:topics).filter(folder_ids: [ 4, 9 ])
```

A `Range` filter matches when any element is in the range. Check `supports_collection_ranges?`
first. A collection field cannot be sorted on.

### Polymorphic indexes

To index several models in one index, declare it `polymorphic: true`:

```ruby
# config/search.rb
ActiveSearch.define_index(:records, polymorphic: true) do
  text :title
  text :body
  integer :account_id
end
```

Two extra fields, `record_type` and `record_id`, record each document's class and id. They are
named after the singular of the index name. To use another name, pass it as the option:

```ruby
ActiveSearch.define_index(:records, polymorphic: :searchable) { ... }   # searchable_type, searchable_id
```

You can declare these two fields yourself, as single-value `string` fields only. The id is stored
as text so that models with different id types can share the index.

`Post.search` on this index filters on `record_type: "Post"`. A filter you add on `record_type`
narrows this and cannot widen it. `ActiveSearch.index(:records)` searches every model.

Connect each model with `has_search index:`:

```ruby
class Post < ApplicationRecord
  has_search index: :records, serializer: :to_content_document

  def to_content_document
    { title: headline, body: body, account_id: account_id }
  end
end

class Page < ApplicationRecord
  has_search index: :records,
    serializer: ->(page) { { title: page.title, body: page.content, account_id: page.account_id } }
end
```

### Models

`has_search` connects a model to an index. Without `index:`, the index is the one named after the
table. It adds callbacks that reindex the record after every create and update, whatever changed,
and remove it after destroy. It adds three methods to the model:

- **`.search("query")`** returns a chainable `Query`. Call it without text for a filter-only query
- **`.suppress_indexing`** and **`.indexing_suppressed?`**
- **`#hit`**, the search metadata of a loaded result

```ruby
class Article < ApplicationRecord
  has_search
end

Article.search("query")
ActiveSearch.index(:articles).filter(status: "published")
```

`suppress_indexing` turns the callbacks off for saves inside the block:

```ruby
articles = Article.where(status: :draft).to_a
Article.suppress_indexing do
  articles.each { |article| article.update!(status: :archived) }
end
```

When the index fields do not match the model's attributes, give `has_search` a serializer that
returns the document hash:

```ruby
class Product < ApplicationRecord
  has_search serializer: ->(r) {
    { name: r.name, description: r.description, price: r.price&.to_f,
      category: r.category, author_name: r.author&.name }
  }
end
```

Or name a method:

```ruby
has_search serializer: :to_search_document
```

A model can be in several indexes. `.search` uses the first one declared, or the one with
`default: true`. Pass `index:` to search another:

```ruby
class Article < ApplicationRecord
  has_search index: :articles
  has_search index: :records, serializer: :to_content_document
end

Article.search("query")                          # :articles
Article.search("query", index: :records)         # :records
```

`touch` does not reindex unless `reindex_on_touch` is set on the index:

```ruby
class Topic < ApplicationRecord
  has_search reindex_on_touch: true
end
```

`touch_all` and `increment!(touch: true)` do not run commit callbacks, so they do not reindex.
Call `reindex` after them.

The other `has_search` options:

- **`async: false`** -- write inline instead of through Active Job
- **Guard options:** `if`, `unless`, `add_if`, `add_unless`, `remove_if`, `remove_unless`
- **`scope:`** -- the relation used to load results. See [Loading records](#loading-records)

`if` and `unless` apply to both the add on save and the remove on destroy. `add_if` and
`add_unless` replace them for the add. `remove_if` and `remove_unless` replace them for the remove.
A saved record that no longer passes its add guard is removed, and only `remove_if` and
`remove_unless` are checked for that removal.

### Manual indexing

`add` and `remove` write at once. `reindex_later` and `remove_later` enqueue an Active Job.
`remove_later` reads the id before the job runs, so it works after the record is destroyed.

```ruby
index = ActiveSearch.index(:articles)
index.add(article)
index.remove(article)
index.reindex_later(article)
index.remove_later(article)

has_search async: false  # write inline for this model
```

`reindex_later` checks the guards when the job runs, so it can remove the document instead of
adding it.

`reindex` applies every `has_search` declaration on the record. It adds the record where the guards
pass and removes it where they fail. The `after_commit` callback calls it, and you can call it
directly:

```ruby
card.reindex

Card.find_each(&:reindex)     # repair after an index loss
```

`ActiveSearch.index(:cards).add(card)` ignores the guards. After a change to what qualifies, use
`reindex`, so that records that no longer qualify are removed.

`reindex` uses each declaration's `async:` setting. An asynchronous index gets a job, and the
others are written inline.

`batch` collects writes and sends them to the store in groups of at most `max_size`:

```ruby
ActiveSearch.index(:articles).batch(max_size: 500) do |batch|
  Article.find_each { |article| batch.add(article) }
end
```

`remove_by_filter` removes every document that matches a filter and returns the count. Use it
after a `delete_all`, which runs no callbacks and so removes nothing from the index:

```ruby
ActiveSearch.index(:searchable).remove_by_filter(account_id: 1)   # => 42
ActiveSearch.index(:records).remove_by_filter(account_id: 1, record_type: "Post")
```

It takes the same filter arguments as `filter`. It has no model type filter, so on a polymorphic
index add the type field, as in the second example. An empty filter raises.

## Searching

### Queries

Each query method returns a new `Query`. Chain them in any order, and call `.results` to run the
search. A `Query` has no `each`, `map` or `count`. `.results` returns the page.

```ruby
ActiveSearch.index(:articles)
  .search("ruby programming")
  .filter(account_id: 1)
  .highlight(title: true)
  .sort(published_at: :desc)
  .limit(20)
  .offset(40)
  .results
```

`operator: :and` requires every term. `fields:` limits the search to the named `text` fields:

```ruby
Article.search("ruby rails", operator: :and)
Article.search("ruby", fields: [ :title ])
```

`operator` is not supported everywhere. Check `supports_operator?`. Without it, each engine uses
its own default.

### Filtering

`filter` narrows the search by a field's value, a list of values or a range:

```ruby
Article.search("rails").filter(account_id: 1)
Article.search("rails").filter(status: "published", account_id: 1)
ActiveSearch.index(:articles).filter(status: ["published", "draft"])
ActiveSearch.index(:articles).filter(views: 100..)            # >= 100
ActiveSearch.index(:articles).filter(views: ..100)            # <= 100
ActiveSearch.index(:articles).filter(views: ...100)           # < 100
ActiveSearch.index(:articles).filter(price: 10..50)           # between 10 and 50
ActiveSearch.index(:articles).filter(created_at: 1.week.ago..)
```

To filter on a missing value, pass `nil`. Check `supports_missing_filters?` first:

```ruby
Article.search("rails").filter(status: nil)                # absent
Article.search("rails").filter(status: [ "draft", nil ])  # draft or absent
Article.search("rails").reject(status: nil)                # present
```

`reject` excludes matches:

```ruby
ActiveSearch.index(:articles).reject(status: "draft")               # status != draft
ActiveSearch.index(:articles).reject(status: ["draft", "archived"]) # NOT IN
ActiveSearch.index(:articles).reject(views: 100..200)               # NOT BETWEEN

# Combined with regular filters
ActiveSearch.index(:articles)
  .filter(account_id: 1)
  .filter(views: 100..)
  .reject(status: "draft")
  .results
```

Several conditions in one `reject` are negated together, like `where.not` in Active Record:

```ruby
reject(status: "draft", featured: true)   # not (draft and featured)
reject(status: "draft").reject(featured: true)   # neither draft nor featured
```

Several values for one field are one condition, so each of them is excluded.

`filter_any` takes an Array of alternatives and requires one of them. Each alternative is a Hash,
and its conditions apply together.

```ruby
# featured, or published this week
ActiveSearch.index(:articles).filter_any([
  { featured: true },
  { status: "published", published_at: 1.week.ago.. }
])
```

An empty list matches nothing. An alternative with no conditions raises. `filter_any` combines with
the other filters through AND:

```ruby
ActiveSearch.index(:articles)
  .filter(account_id: 1)
  .filter_any([ { featured: true }, { status: "published" } ])
```

### Highlighting

```ruby
results = Article.search("ruby").highlight(true).results

results.each do |result|
  result.hit.highlight(:title)   # => "<mark>Ruby</mark> Programming Guide"
  result.hit.highlight(:content) # => nil, because nothing in content matched
end
```

A field with no match has no highlight, and `hit.highlight` returns `nil` for it on every adapter.
Fall back to the field value when you want one:

```ruby
result.hit.highlight(:content) || result.content

# Per-field with snippets and custom markers
Article.search("ruby").highlight(
  title: { markers: ["<em>", "</em>"] },
  content: { snippet: { words: 15 } }       # or { characters: 150 }
)
```

`highlight` takes `format`, `markers` and `snippet`. Any other key raises. Set backend options
through `native`.

Different options on different fields need `supports_highlight_per_field_markers?` and
`supports_highlight_per_field_snippets?`. A field with no snippet counts as a different snippet
setting:

```ruby
# Needs supports_highlight_per_field_markers?
Article.search("ruby").highlight(title: { markers: ["<em>", "</em>"] },
                                 content: { markers: ["<b>", "</b>"] })

# Both need supports_highlight_per_field_snippets?
Article.search("ruby").highlight(title: { snippet: { words: 5 } },
                                 content: { snippet: { words: 15 } })

Article.search("ruby").highlight(title: true,
                                 content: { snippet: { words: 15 } })
```

### Results

```ruby
results = Article.search("rails").highlight.results

results.total          # documents that matched, across all pages
results.total_exact?   # false when the total is an estimate or a lower bound
results.partial?       # true when the store stopped early
results.dropped        # hits on this page with no record to load
results.size           # records on this page
results.empty?
results.next_page?     # true when the store has hits beyond this page

results.each do |article|
  article.hit.score
  article.hit.highlight(:title)  # nil unless .highlight was called
  article.hit.fields[:status]
end
```

Each result is the record. `hit.fields` holds every declared field, and `hit_fields` limits it:

```ruby
results = Article.search("rails").hit_fields(:status).results
```

`total` counts index hits. `size` counts the records loaded for this page. Some stores report an
estimate or a lower bound, and then `total_exact?` is false.

Use `next_page?` to page. `false` means the store returned no further hits. On a `partial?` page
there can still be matches the store did not reach.

`partial?` is true when the store stopped early, for example on a timeout. Then `total` may be low
and `next_page?` may be false with matches unseen.

```ruby
results = Article.search("rails").results
render_warning if results.partial?
```

A query without `limit` uses `config.active_search.default_limit`, which is 25.

```ruby
# config/initializers/active_search.rb
Rails.application.config.active_search.default_limit = 50
Rails.application.config.active_search.default_limit = nil  # no limit, each store applies its own

# No limit for one query:
query.limit(nil).to_native_query
```

### Loading records

A search returns document ids, and the source loads the records with `Model.where(id: ids)`. Set
`scope:` on the model or on the query to load them through another relation:

```ruby
class Recording < ApplicationRecord
  has_search scope: -> { not_removed }
end

Recording.search("q")                                             # the model's default
Recording.search("q", scope: Recording.preload(:creator))         # this query only
Topic.search("q", scope: identity.accessible_topics)              # a relation built per request
```

The query's relation is merged into the model's default with `ActiveRecord::Relation#merge`.

A scope does not filter the search. The store chooses the page of hits first, and the scope only
loads them. Hits the scope excludes are counted in `results.dropped`.

### Routing

On Elasticsearch and OpenSearch, `route_by` stores each document on a shard chosen by a field, and a search that filters on that
field reads only that shard:

```ruby
# config/search.rb
ActiveSearch.define_index(:articles, route_by: :account_id) do
  text :title
  integer :account_id
end

Article.search("q").filter(account_id: 1).results          # one shard
Article.search("q").filter(account_id: [ 1, 2 ]).results   # two shards
Article.search("q").filter(account_id: 1..5).results       # QueryError
```

A negated filter, or a `filter_any` with an alternative that does not name the field, reads every
shard. `Query#routing` returns the route, or nil.

Do not change a record's `route_by` value. The old document stays on the old shard, and a later
destroy does not reach it.

Test routing on an index with more than one shard. With one shard, a wrong route still returns
everything.

### Native queries

`to_native_query` returns the request as built. `native` takes a block to change it before it is
sent.

> **Treat a `native` block as trusted code.** Its return value is sent to the backend without
> validation. It can remove [the model's type filter](#polymorphic-indexes). Never pass untrusted
> parameters into it.

**Search engine adapters** return a hash:

```ruby
ActiveSearch.index(:articles).search("ruby").to_native_query
# => { query: { bool: { must: { simple_query_string: {...} } } } }

# Modify the query before execution
ActiveSearch.index(:articles).search("ruby").native { |query|
  query[:timeout] = "5s"
  query
}.results
```

**Database adapters** (SQLite, PostgreSQL, MySQL) return an Active Record relation on the document
model. To merge it into a query on your model, join the document table first. Document ids are
stored as strings, so the join casts. On MySQL cast to `CHAR`:

```ruby
search = ActiveSearch.index(:articles).search("ruby").to_native_query
doc_table = search.model.table_name

Article
  .select("articles.*")
  .joins("INNER JOIN #{doc_table} ON #{doc_table}.article_id = CAST(articles.id AS TEXT)")
  .merge(search)
```

## Adapters

### Capabilities

Every adapter supports text search, exact, negative, IN and range filters, sorting, pagination and
hit fields. The rest depends on the adapter. Check the index's capabilities. An unsupported operation raises
`UnsupportedOperationError`.

```ruby
capabilities = ActiveSearch.index(:articles).capabilities
capabilities.supports_highlighting?
capabilities.supports_operator?
capabilities.supports_missing_filters?
capabilities.supports_search_subfields?
capabilities.supports_search_string_fields?
capabilities.supports_collection_ranges?  # a range over a multiple: field
capabilities.supports_snippet_unit?(:words)     # or :characters
```

| Adapter | highlight | snippet units | per-field markers | per-field snippets | `operator:` | missing filters | subfields | string-field search | collection ranges |
|---|---|---|---|---|---|---|---|---|---|
| Elasticsearch | yes | characters | yes | yes | yes | yes | yes | yes | yes |
| OpenSearch | yes | characters | yes | yes | yes | yes | yes | yes | yes |
| Solr | yes | characters | yes | yes | yes | yes | no | no | yes |
| Meilisearch | yes | words | yes | yes | no | yes | no | no | no |
| Typesense | yes | words | yes | no | yes | no | no | no | no |
| PostgreSQL | yes | words | yes | yes | no | yes | no | no | yes |
| SQLite | yes | words | yes | yes | no | yes | no | no | yes |
| MySQL | no | none | no | no | no | yes | no | no | no |
| Redis Search | yes | none | no | no | no | yes | no | no | no |
| Manticore | yes | characters | no | no | no | no | no | no | yes |

### Documented divergences

Each of these is a property of the backend, and each is asserted in the test suite.

- **Redis Search needs 2.10 or later, query dialect 2, and `INDEXMISSING` on every filterable
  field.** Dialect 2 provides `ismissing()`, which is used for missing-value filters and for an
  empty filter list.
- **Typesense approximates `operator: :or`.** It maps to `drop_tokens_threshold`, so terms are
  dropped only when the full match finds fewer than 100 documents.
- **Solr does not distinguish `""` from an absent field.** It indexes no term for an empty string,
  so an existence filter does not find it. `false` and zero are unaffected. An empty collection
  also reads back as absent. Every other adapter keeps the two apart.
- **SQLite sorts relevance ascending.** FTS5 rank is negative, and the best match is the most
  negative.
- **Redis Search filters integers as doubles**, so values above 53 bits are not distinct in a
  filter. They are stored and read back intact. Declare such a field as `string` if you filter on
  it.
- **Redis Search indexes every collection as TAG.** The values are joined with U+001F, so the
  `FT.CREATE` schema must declare `SEPARATOR "\x1f"` on the field, and a value containing U+001F
  is not supported. `[ "" ]` and `[]` both read back as `[]`.
- **Manticore has no NULL.** An absent text field reads back as `""`. Every other adapter returns
  `nil`.
- **Manticore stores an integer collection as a multi-value attribute, which is a set.**
  `(3, 1, 3)` reads back as `1, 3`. Other collection types go in a `json` column, which keeps order
  and duplicates.

### Verified versions

Every claim in this README is tested against the versions in `docker-compose.yml`, pinned by
digest.

| Store | Version under test |
|---|---|
| Elasticsearch | `9.5.2`, `8.19.20` **and** `7.17.18` |
| OpenSearch | `3.8.0` |
| Solr | `9.10.1` |
| Meilisearch | `v1.53.1` |
| Typesense | `30.2` |
| Redis Stack | `7.4.0-v8` |
| Manticore | `29.0.2` |
| MySQL | `8.4` |
| PostgreSQL | `18` |
| SQLite | whatever the `sqlite3` gem bundles |

Each Elasticsearch major is tested with its own client, because a client only works with its own
major.

For a version not in the table, run the shared adapter tests in
`test/store_adapters/adapter_test.rb` against it.

### Custom adapters

To write a source or an adapter of your own, see [docs/custom_adapters.md](docs/custom_adapters.md).

## Commands

```bash
rails active_search:install   # Write config/search.yml and config/search.rb (ADAPTER=name)
rails active_search:status    # What exists, and what to do next
rails active_search:health    # Ping each store; database adapters answer without a connection
rails active_search:verify    # Does each index provide what its declaration needs
```

`install` writes sqlite for development and test. Pass `ADAPTER` for another:

```bash
rails active_search:install ADAPTER=elasticsearch
```

Each adapter defaults to localhost on its own port. Typesense has no default key, so set
`TYPESENSE_API_KEY`. See [Configuration](#configuration) for the other settings.

To declare an index and connect its model:

```bash
rails generate active_search:index Article title body:text status:string views:integer
```

This writes the `define_index` block into `config/search.rb` and adds `has_search` to the model.
On a database adapter it also writes the document model and its migration. A field with no type
is `text`, and a third segment is a modifier:

```bash
rails generate active_search:index Article commenters:string:multiple
```

`status` and `verify` take `INDEX=name` for one index. `status` takes `COUNT=1` to count the
documents in each index.

`verify` exits non-zero when anything is wrong, so it can run in CI or before a deploy:

| Code | Outcome | Meaning |
|---|---|---|
| 0 | compatible | Every index provides what its declaration needs |
| 1 | incompatible | The index exists but a declared field is missing or unusable |
| 2 | missing | The index does not exist |
| 3 | unavailable | The store did not answer in time |
| 4 | unsupported | The adapter cannot inspect itself, so nothing was checked |
| 5 | error | The check raised, or no index is declared |

A run over several indexes exits with the worst code. Codes 3, 4 and 5 mean the check did not run.

To create an index on a search engine:

```bash
rails active_search:index:create INDEX=articles
```

This creates the fields in the declaration, and is safe to run again. Set analyzers through the
engine's own API. Solr needs its core created with Solr's tools first.

On a database adapter, generate the document model and its migration, then migrate:

```bash
rails generate active_search:document articles
rails db:migrate
```

## Instrumentation

Five `ActiveSupport::Notifications` events:

| Event | Payload |
|---|---|
| `search.active_search` | `index`, `store_name`, `query_length`, `total`, `total_relation`, `partial_results`, and `store_metrics` |
| `add.active_search` | `index`, `store_name`, `document_id` |
| `remove.active_search` | `index`, `store_name`, `document_id` |
| `flush_batch.active_search` | `index`, `store_name`, `operations` |
| `remove_by_filter.active_search` | `index`, `store_name`, `removed` |

`store_name` is the key from `config/search.yml`, or `:default`. `total_relation` is `:equal`,
`:lower_bound` or `:estimate`. Duration comes from the event.

The search payload carries `query_length`, not the query text. `ActiveSearch.filter_attributes`
lists payload values to filter. It defaults to `config.filter_parameters`.

## Limitations

- **Query syntax.** There is no common syntax. Each adapter sends the query string to its engine,
  with the escaping that engine needs.
- **Index management.** `index:create` builds a search engine index. Solr cores and database
  tables are created outside it. See [Commands](#commands).
- **Analyzers.** Stemming, synonyms and other text analysis are set in the engine. On SQLite, see
  the FTS5 tokenizer under [Configuration](#configuration).
- **Advanced features.** No aggregations, nested documents, grouping or autocomplete.
- **Redis Search.** A document whose every field is nil is not stored, so a missing-value filter
  does not find it. The next write with any field present stores it.

## License

MIT License
