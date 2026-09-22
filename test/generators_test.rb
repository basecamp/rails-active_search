require "test_helper"
require "rails/generators"
require "open3"
require "generated_app"
require "generators/active_search/install/install_generator"
require "generators/active_search/index/index_generator"

class GeneratorsTest < ActiveSupport::TestCase
  setup do
    @registered = ActiveSearch.index_names
    @root = Pathname.new(Dir.mktmpdir("as-generators"))
    write_model "widget.rb", <<~RUBY
      class Widget < ApplicationRecord
        self.table_name = "widgets"
      end
    RUBY
  end

  teardown do
    (ActiveSearch.index_names - @registered).each { |name| ActiveSearch.configuration.unregister_index(name) }
    FileUtils.remove_entry(@root) if @root.exist?
    %i[ Widget Shop Gadget Doodad ].each { |name| Object.send(:remove_const, name) if Object.const_defined?(name, false) }
  end

  test "install writes both config files, and the yaml parses" do
    install

    assert_predicate @root.join("config/search.rb"), :exist?
    parsed = YAML.safe_load(ERB.new(@root.join("config/search.yml").read).result, aliases: true)

    assert_equal %w[ development test ], parsed.keys
    assert_equal "sqlite", parsed.dig("test", "adapter")
  end

  test "the generated search.yml writes bare scalars, like database.yml, not quoted" do
    run_generator ActiveSearch::Generators::InstallGenerator, [], adapter: "meilisearch"
    raw = @root.join("config/search.yml").read

    assert_match(/^  adapter: meilisearch$/, raw)
    assert_match(/^  index_prefix: development_$/, raw)
    assert_no_match(/adapter: "meilisearch"/, raw)
  end

  test "install writes the adapter it is given" do
    ActiveSearch.configuration.registered_adapter_names.each do |name|
      root = Pathname.new(Dir.mktmpdir("as-adapter"))
      capture_io do
        ActiveSearch::Generators::InstallGenerator
          .new([], { adapter: name.to_s }, destination_root: root).invoke_all
      end
      parsed = YAML.safe_load(ERB.new(root.join("config/search.yml").read).result, aliases: true)

      assert_equal name.to_s, parsed.dig("development", "adapter"), name
      assert_equal name.to_s, parsed.dig("test", "adapter"), name

      if %i[ sqlite mysql postgresql ].include?(name)
        assert_nil parsed.dig("development", "index_prefix"), name
        assert_nil parsed.dig("test", "index_prefix"), name
      else
        assert_equal "development_", parsed.dig("development", "index_prefix"), name
        assert_equal "test_", parsed.dig("test", "index_prefix"), name
      end
    ensure
      FileUtils.remove_entry(root) if root.exist?
    end
  end

  test "typesense is given a key that survives the round trip" do
    run_generator ActiveSearch::Generators::InstallGenerator, [], adapter: "typesense"
    key = "a: awkward # key"

    parsed = with_env("TYPESENSE_API_KEY" => key) do
      YAML.safe_load(ERB.new(@root.join("config/search.yml").read).result, aliases: true)
    end

    assert_equal key, parsed.dig("development", "api_key")
    assert_equal key, parsed.dig("test", "api_key")
  end

  test "both documented ways in reach a real application" do
    generated = GeneratedApp.build

    { %w[ generate active_search:install --adapter=meilisearch ] => {},
      %w[ active_search:install ] => { "ADAPTER" => "meilisearch" } }.each do |argv, env|
      FileUtils.rm_f(generated.app + "config/search.yml")
      output, status = generated.rails(*argv, env: env)

      assert_predicate status, :success?, output
      parsed = YAML.safe_load(ERB.new(generated.read("config/search.yml")).result, aliases: true)
      assert_equal "meilisearch", parsed.dig("development", "adapter"), argv.join(" ")
    end
  ensure
    generated&.remove
  end

  test "an adapter that is not registered is refused, naming the ones that are" do
    error = assert_raises(Rails::Generators::Error) do
      run_generator ActiveSearch::Generators::InstallGenerator, [], adapter: "nonsense"
    end

    assert_match "Unknown adapter :nonsense", error.message
    assert_match "sqlite", error.message
  end

  test "a declaration is appended, and a bare field is text" do
    install
    generate %w[ Widget title body:text views:integer tags:string:multiple ]

    assert_equal <<~RUBY.strip, declaration
      ActiveSearch.define_index(:widgets) do
        text :title
        text :body
        integer :views
        string :tags, multiple: true
      end
    RUBY
  end

  test "the document class and its migration are written when the store needs them" do
    install
    generate %w[ Widget title ]
    document = @root.join("app/models/widget_document.rb")

    if database_adapter?
      assert_predicate ActiveSearch.index(:widgets).store, :generates_document_class?
      assert_predicate document, :exist?
      assert_equal 1, Dir.glob("#{@root}/db/migrate/*_create_widget_documents.rb").size
    else
      assert_not ActiveSearch.index(:widgets).store.generates_document_class?
      assert_not document.exist?
      assert_empty Dir.glob("#{@root}/db/migrate/*.rb")
    end
  end

  test "has_search is added bare, because it infers the name the declaration uses" do
    install
    generate %w[ Widget title ]

    assert_match(/^  has_search$/, @root.join("app/models/widget.rb").read)
  end

  test "the index takes the name Rails gives the table, not the one the class name suggests" do
    write_model "shop/order.rb", <<~RUBY
      module Shop
        class Order < ApplicationRecord
          self.table_name = "orders"
        end
      end
    RUBY
    install
    generate %w[ Shop::Order title ]

    assert_match(/define_index\(:orders, source: "Shop::Order"\)/, @root.join("config/search.rb").read)
    assert_match(/^  has_search$/, @root.join("app/models/shop/order.rb").read)
  end

  test "a namespaced model is named as the source" do
    write_model "shop/order.rb", <<~RUBY
      module Shop
        class Order < ApplicationRecord
          self.table_name = "authors"
        end
      end
    RUBY
    install
    generate %w[ Shop::Order title ]

    eval declaration
    assert_equal Shop::Order, ActiveSearch.index(:authors).source.model_class
  ensure
    ActiveSearch.configuration.unregister_index(:authors)
  end

  test "a model that already declares this index is left alone" do
    write_model "widget.rb", "class Widget < ApplicationRecord\n  self.table_name = \"widgets\"\n  has_search\nend\n"
    install
    generate %w[ Widget title ]

    assert_equal [ "  has_search" ], has_search_lines
  end

  test "a model declaring another index still gets this one" do
    write_model "widget.rb",
      "class Widget < ApplicationRecord\n  self.table_name = \"widgets\"\n  has_search index: :other\nend\n"
    install
    generate %w[ Widget title ]

    assert_equal [ "  has_search", "  has_search index: :other" ], has_search_lines.sort
  end

  test "an index already declared is not declared again" do
    install
    ActiveSearch.define_index(:widgets) { text :title }
    generate %w[ Widget title body:text ]

    assert_equal 0, @root.join("config/search.rb").read.scan(/^ActiveSearch\.define_index/).size
  ensure
    ActiveSearch.configuration.unregister_index(:widgets)
  end

  test "an unknown type names the ones that exist" do
    install
    error = assert_raises(Rails::Generators::Error) { generate %w[ Widget title:blob ] }

    assert_match "Unknown field type :blob", error.message
    assert_match "text, string, integer", error.message
  end

  test "a name that would not parse is refused" do
    install
    error = assert_raises(Rails::Generators::Error) { generate [ "Widget", "foo bar:text" ] }

    assert_match "is not a field name", error.message
  end

  test "multiple on a type that cannot hold a collection is refused" do
    install
    error = assert_raises(Rails::Generators::Error) { generate %w[ Widget body:text:multiple ] }

    assert_match "cannot be multiple:", error.message
  end

  test "an unknown modifier is refused rather than dropped" do
    install
    error = assert_raises(Rails::Generators::Error) { generate %w[ Widget title:text:uniq ] }

    assert_match "Unknown modifier uniq", error.message
  end

  test "a table the gem cannot name is refused" do
    write_model "widget.rb", "class Widget < ApplicationRecord\n  self.table_name = \"public.widgets\"\nend\n"
    install
    error = assert_raises(Rails::Generators::Error) { generate %w[ Widget title ] }

    assert_match "not a name an index can take", error.message
  end

  test "a field named twice is refused before anything is written" do
    install
    before = @root.join("config/search.rb").read
    error = assert_raises(Rails::Generators::Error) { generate %w[ Widget title title ] }

    assert_match "declares :title twice", error.message
    assert_equal before, @root.join("config/search.rb").read
    assert_empty has_search_lines
  end

  test "no fields is refused" do
    install
    error = assert_raises(Rails::Generators::Error) { generate %w[ Widget ] }

    assert_match "Give at least one field", error.message
  end

  test "a class that only answers table_name is refused" do
    write_model "gadget.rb", "class Gadget\n  def self.table_name = \"gadgets\"\nend\n"
    install
    error = assert_raises(Rails::Generators::Error) { generate %w[ Gadget title ] }

    assert_match "Gadget is not an Active Record model", error.message
  end

  test "a model that is not in app/models is refused" do
    install
    error = assert_raises(Rails::Generators::Error) { generate %w[ Author title ] }

    assert_match "app/models/author.rb is not there", error.message
    assert_equal 0, @root.join("config/search.rb").read.scan(/^ActiveSearch\.define_index/).size
  end

  test "destroy takes back the declaration and the macro" do
    install
    before = @root.join("config/search.rb").read
    generate %w[ Widget title ]

    ActiveSearch.define_index(:widgets) { text :title }
    Widget.has_search
    revoke %w[ Widget title ]

    assert_equal before, @root.join("config/search.rb").read
    assert_empty has_search_lines
  ensure
    ActiveSearch.configuration.unregister_index(:widgets)
  end

  test "a model that is not there is refused" do
    install
    error = assert_raises(Rails::Generators::Error) { generate %w[ Absent title ] }

    assert_match "Absent is not an Active Record model", error.message
  end

  test "declaring without config/search.rb says how to get one" do
    error = assert_raises(Rails::Generators::Error) { generate %w[ Widget title ] }

    assert_match "rails active_search:install", error.message
  end

  test "an application resolves the plain model name, and a second run declares nothing twice" do
    generated = GeneratedApp.build
    generated.rails("generate", "model", "article", "title:string")
    generated.rails("active_search:install")

    first = generated.rails("generate", "active_search:index", "Article", "title")
    second = generated.rails("generate", "active_search:index", "Article", "title")

    assert_predicate first.last, :success?, first.first
    assert_equal 1, generated.read("config/search.rb").scan(/^ActiveSearch\.define_index/).size
    assert_match ":articles is already declared", second.first
    assert_match "Article already declares :articles", second.first
    assert_equal [ "  has_search" ], generated.read("app/models/article.rb").lines.grep(/has_search/).map(&:chomp)
  ensure
    generated&.remove
  end

  private
    def database_adapter?
      %i[ sqlite mysql postgresql ].include?(store_adapter_name)
    end

    def write_model(path, source)
      @root.join("app/models", path).tap do |file|
        file.dirname.mkpath
        file.write(source)
        load file.to_s
      end
    end

    def with_env(values)
      previous = values.transform_values { |_| nil }.merge(ENV.slice(*values.keys))
      ENV.update(values)
      yield
    ensure
      previous.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
    end

    def has_search_lines
      @root.join("app/models/widget.rb").read.lines.grep(/has_search/).map(&:chomp)
    end

    def declaration
      @root.join("config/search.rb").read.scan(/^ActiveSearch\.define_index.*?\nend/m).last.strip
    end

    def install
      run_generator ActiveSearch::Generators::InstallGenerator, []
    end

    def generate(args)
      run_generator ActiveSearch::Generators::IndexGenerator, args
    end

    def revoke(args)
      capture_io do
        ActiveSearch::Generators::IndexGenerator
          .new(args, [], destination_root: @root, behavior: :revoke).invoke_all
      end
    end

    def run_generator(klass, args, **options)
      capture_io { klass.new(args, options, destination_root: @root).invoke_all }
    end
end
