# Custom sources and adapters

## Custom sources

A source loads the records for a page of hits. The default loads Active Record models. Any object
with `records_for(ids)` and `id_for(record)` can be a source. The objects it returns must include
`ActiveSearch::Resultable`, which adds `hit`:

```ruby
class Card
  include ActiveSearch::Resultable
end

Card.new.hit          # nil until it comes from a search
result.hit.score      # after hydration
result.hit.highlight(:title)
```

`hit` is nil on an object that did not come from a search. `has_search` includes `Resultable` for
you.

## Custom adapters

The `adapter:` name in `config/search.yml` is looked up in a registry. Register your own adapter by
class name:

```ruby
# config/search.rb, or config/initializers/active_search.rb
ActiveSearch.register_adapter :my_store, "My::StoreAdapter"
```

The class and its client library are loaded when the adapter is first used. Passing the class
itself raises. A later registration replaces an earlier one.

```yaml
# config/search.yml
production:
  adapter: my_store
```

An unregistered name raises `ConfigurationError`. The class must inherit from
`ActiveSearch::StoreAdapters::Base` and implement `write`, `delete`, `flush`, `build_raw_query`,
`execute_query`, `capabilities` and `ping`. Base implements the public `add`, `remove`,
`flush_batch` and `search`, and turns the exceptions listed in the adapter's `CLIENT_ERRORS` into
`ActiveSearch::AdapterError`.

A store is built once and kept. An adapter defined in the application is reloaded with the rest of
the code.

### Configuration errors

A store is built on first use, so `config/search.yml` is checked then, as `database.yml` is checked
on first connection.

    ConfigurationError: Unknown store :analytics. Configured stores are primary, secondary.
    ConfigurationError: Adapter :meilisearch could not load its client library: cannot load such
                        file -- meilisearch. Add it to your Gemfile.

A store name that is not configured raises. There is no fallback to the default store.
