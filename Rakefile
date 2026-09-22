require "bundler/setup"

APP_RAKEFILE = File.expand_path("test/dummy/Rakefile", __dir__)
load "rails/tasks/engine.rake"

require "bundler/gem_tasks"

Rake::Task["test"].clear if Rake::Task.task_defined?("test")

DOCKER_SERVICES = {
  "mysql" => "mysql",
  "postgresql" => "postgres",
  "elasticsearch" => "elasticsearch",
  "opensearch" => "opensearch",
  "meilisearch" => "meilisearch",
  "typesense" => "typesense",
  "solr" => "solr",
  "redis_search" => "redis",
  "manticore" => "manticore"
}

task "docker:up" do
  adapters = ENV.fetch("SEARCH_ADAPTER", DOCKER_SERVICES.keys.join(",")).split(",")
  services = adapters.filter_map { |a| DOCKER_SERVICES[a.strip] }.uniq

  if services.any?
    puts "Starting Docker services: #{services.join(", ")}"
    system("docker compose up --detach --wait #{services.join(" ")}", exception: true)
  end
end

task default: :test

desc "Run adapter tests for all search adapters in sequence"
task test: [ "docker:up", :environment ] do
  adapters = [
    { name: "sqlite", env: { "SEARCH_ADAPTER" => "sqlite" } },
    { name: "mysql", env: { "SEARCH_ADAPTER" => "mysql", "DB_ADAPTER" => "mysql", "MYSQL_PASSWORD" => "password" } },
    { name: "postgresql", env: { "SEARCH_ADAPTER" => "postgresql", "DB_ADAPTER" => "postgresql" } },
    { name: "elasticsearch", env: { "SEARCH_ADAPTER" => "elasticsearch" } },
    { name: "opensearch", env: { "SEARCH_ADAPTER" => "opensearch" } },
    { name: "meilisearch", env: { "SEARCH_ADAPTER" => "meilisearch" } },
    { name: "typesense", env: { "SEARCH_ADAPTER" => "typesense" } },
    { name: "solr", env: { "SEARCH_ADAPTER" => "solr" } },
    { name: "redis_search", env: { "SEARCH_ADAPTER" => "redis_search" } },
    { name: "manticore", env: { "SEARCH_ADAPTER" => "manticore" } }
  ]
  results = {}

  adapters.each do |adapter|
    puts "\n#{"=" * 60}"
    puts "Running tests for #{adapter[:name].upcase}"
    puts "=" * 60

    success = system(adapter[:env], "bin/rails", "test")
    results[adapter[:name]] = success
  end

  puts "\n#{"=" * 60}"
  puts "SUMMARY"
  puts "=" * 60

  results.each do |adapter, success|
    status = success ? "PASS" : "FAIL"
    puts "#{adapter.ljust(15)} #{status}"
  end

  failed = results.reject { |_, success| success }.keys
  if failed.any?
    puts "\nFailed adapters: #{failed.join(", ")}"
    exit 1
  else
    puts "\nAll adapters passed!"
  end
end
