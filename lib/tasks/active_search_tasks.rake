namespace :active_search do
  # Exit codes are part of the contract, because a script reads them:
  #   0 every index compatible   1 incompatible   2 missing
  #   3 unavailable   4 unsupported   5 error
  # A run over several indexes exits with the worst one it saw.
  desc "Check each index still provides what its declaration needs (INDEX=name for one)"
  task verify: :environment do
    names = ENV["INDEX"] ? [ ENV["INDEX"].to_sym ] : ActiveSearch.index_names

    # Not 0. Nothing was checked, and a gate reading 0 would take that for every index
    # providing what it needs. status says the same thing and exits 0, because it does not gate.
    if names.empty?
      warn "error    no indexes are declared. Check that config/search.rb is loaded."
      exit ActiveSearch::Schema::Verification::EXIT_CODES.fetch(:error)
    end

    width = names.map { |name| name.to_s.length }.max
    worst = nil

    names.each do |name|
      verification = ActiveSearch::Schema.verify(ActiveSearch.index(name))
      puts "#{name.to_s.ljust(width)}  #{verification.describe}"
      worst = verification if worst.nil? || verification.severity > worst.severity
    end

    exit worst.exit_code unless worst.compatible?
  end

  desc "What exists, and what to do next (INDEX=name for one, COUNT=1 to count documents)"
  task status: :environment do
    names = ENV["INDEX"] ? [ ENV["INDEX"].to_sym ] : ActiveSearch.index_names

    if names.empty?
      puts "No indexes are declared."
      next
    end

    width = names.map { |name| name.to_s.length }.max
    ready = 0

    # A count is a query, and on a database it counts the whole table. Asked for, not assumed.
    counting = ENV["COUNT"].present?

    names.each do |name|
      index = ActiveSearch.index(name)
      verification = ActiveSearch::Schema.verify(index)
      population = counting ? ActiveSearch::Schema.population_of(index, verification) : :not_applicable
      ready += 1 if verification.compatible?

      counted = case population
      when :not_applicable then nil
      when :unknown then "count unknown"
      else "#{population} #{"document".pluralize(population)}"
      end

      puts "  #{name.to_s.ljust(width)}  #{ActiveSearch::Schema.store_label(index).ljust(14)}  " \
        "#{[ verification.describe, counted ].compact.join(", ")}"

      step = ActiveSearch::Schema.next_step_for(index, verification)
      puts "  #{" " * width}  #{" " * 14}  -> #{step}" if step
    end

    puts
    puts "  #{names.size} #{names.one? ? "index" : "indexes"}, #{ready} ready"
  end

  namespace :index do
    desc "Create an index that does not exist yet (INDEX=name is required)"
    task create: :environment do
      name = ENV["INDEX"]
      abort "INDEX=name is required. Creating every index at once is not offered." if name.blank?

      index = ActiveSearch.index(name.to_sym)
      plan = index.store.create_index(index)

      puts "#{plan.applied ? "ready" : "wrote"}  #{name} (#{ActiveSearch::Schema.store_label(index)})"
      puts plan.summary
    rescue ActiveSearch::Schema::CreationRefused, NotImplementedError => e
      abort "refused  #{e.message}"
    rescue StandardError => e
      # An adapter is allowed to refuse the question. Reporting that beats a stack trace, which
      # is what verify already does for the same call.
      abort "error    #{e.class}: #{e.message}"
    end
  end

  desc "Write config/search.yml and config/search.rb (ADAPTER=name for a store other than sqlite)"
  task install: :environment do
    require "generators/active_search/install/install_generator"
    options = ENV["ADAPTER"] ? { adapter: ENV["ADAPTER"] } : {}
    ActiveSearch::Generators::InstallGenerator.new([], options, destination_root: Rails.root).invoke_all
  rescue Rails::Generators::Error => e
    abort "refused  #{e.message}"
  end

  desc "Check connectivity to each configured search store"
  task health: :environment do
    config = ActiveSearch.configuration
    failed = false
    config.store_names.each do |name|
      store = config.store_for(name)
      print "#{name} (#{store.class.name}): "
      begin
        # Every adapter rescues internally and answers false, so the return value is the result.
        if store.ping
          puts "OK"
        else
          failed = true
          puts "FAIL - did not answer"
        end
      rescue => e
        failed = true
        puts "FAIL - #{e.class}: #{e.message}"
      end
    end
    exit 1 if failed
  end
end
