require "tmpdir"
require "open3"

# A real application to run rails generate against, the way railties tests do. rails generate writes
# to the application root whatever directory it runs in, so test/dummy is not somewhere to point it.
class GeneratedApp
  # Minimal, and with no asset pipeline: a generated environment file calls config.assets, which
  # needs a gem this one does not bundle.
  NEW_OPTIONS = %w[ --minimal --skip-asset-pipeline --skip-git --skip-bundle --quiet ].freeze

  attr_reader :root

  # Built here rather than in the constructor, so a failure still has an object to clean up through.
  def self.build
    new.tap(&:create)
  end

  def initialize
    @root = Pathname.new(Dir.mktmpdir("as-app"))
  end

  def create
    # Through bundler, which finds railties wherever it is installed. Its executable run directly
    # cannot load rails/cli from a vendored bundle, and rails on PATH is this engine's binstub.
    run "bundle", "exec", "rails", "new", "app", *NEW_OPTIONS, chdir: root.to_s
    run_under_this_bundle
  rescue StandardError
    remove
    raise
  end

  def app
    root + "app"
  end

  def rails(*argv, env: {})
    run("bin/rails", *argv, chdir: app.to_s, env: env, check: false)
  end

  def read(path)
    (app + path).read
  end

  def remove
    FileUtils.remove_entry(root) if root.exist?
  end

  private
    # The application never installs a bundle of its own. It runs on this one, which already holds
    # rails and this gem, so no test needs the network to resolve anything.
    def run_under_this_bundle
      # rails, not rails/all: a minimal application configures none of the other frameworks, and
      # Active Storage refuses to initialize without the storage.yml it therefore has no reason to have.
      (app + "config/boot.rb").write(%(require "rails"\n))
      application = app + "config/application.rb"
      # active_job, because this gem's app/jobs subclass ActiveJob::Base and a minimal application
      # loads neither.
      application.write(application.read.sub(/^Bundler\.require.*$/,
        %(require "active_job/railtie"\nrequire "active_search")))
    end

    def run(*argv, chdir:, env: {}, check: true)
      output, status = Open3.capture2e(env, *argv, chdir: chdir)
      raise "#{argv.join(" ")} failed:\n#{output}" if check && !status.success?

      [ output, status ]
    end
end
