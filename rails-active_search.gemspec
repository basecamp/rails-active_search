require_relative "lib/active_search/version"

Gem::Specification.new do |spec|
  spec.name        = "rails-active_search"
  spec.version     = ActiveSearch::VERSION
  spec.authors     = [ "Donal McBreen" ]
  spec.email       = [ "donal@37signals.com" ]
  spec.homepage    = "https://github.com/basecamp/rails-active_search"
  spec.summary     = "Pluggable search engine adapter for Rails"
  spec.description = "ActiveSearch provides a unified interface for full-text search across Elasticsearch, MySQL FULLTEXT, and SQLite FTS5"
  spec.license     = "MIT"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib}/**/*", "MIT-LICENSE", "Rakefile", "README.md"]
  end

  # What CI verifies, rather than a wider claim nothing tests.
  spec.required_ruby_version = ">= 3.2"
  spec.add_dependency "rails", ">= 8.1"

  spec.extra_rdoc_files = [ "README.md" ]
  spec.rdoc_options = [
    "--title", "ActiveSearch",
    "--main", "README.md"
  ]
end
