require "test_helper"
require "generators/active_search/document/document_generator"

class DatabaseMigrationTest < ActiveSupport::TestCase
  setup do
    skip "only a database adapter builds an index by migration" unless database_adapter?
    @index = ActiveSearch.index(:creation_probes)
    @source = @index.store.migration_source(@index)
  end

  teardown { drop_tables if database_adapter? }

  test "the migration it writes builds an index that verifies against the declaration" do
    assert_not table_exists?

    run_migration(:up)

    assert table_exists?, "the migration ran and made no table"
    verification = ActiveSearch::Schema.verify(@index)
    assert verification.compatible?, verification.describe
  end

  test "a declaration with collections builds an index that filters one" do
    index = ActiveSearch.index(:collection_probes)
    source = index.store.migration_source(index)
    assert_nil source.refusal

    begin
      Object.class_eval(source.to_ruby) # rubocop:disable Security/Eval
      migration = Object.const_get(source.class_name)
      migration.migrate(:up)

      verification = ActiveSearch::Schema.verify(index)
      assert verification.compatible?, verification.describe

      index.store.write(index, ActiveSearch::Document.new(id: 1, definition: index.definition,
        data: { title: "ruby collections", account_id: 1, folder_ids: [ 3, 7 ], labels: %w[ red blue ] }))

      assert_equal 1, index.search("ruby").results.total, "the text half of the index does not answer"
      assert_equal 1, index.all.filter(folder_ids: 7).results.total, "the collection column does not filter"
      assert_equal 0, index.all.filter(folder_ids: 9).results.total, "control: an absent value matches"
    ensure
      migration&.migrate(:down)
    end
  end

  test "an identifier too long for this database is refused before the migration is written" do
    long = ("a" * 64).to_sym
    ActiveSearch.define_index(:byte_probe, source: "Article") { text :title; string long }
    index = ActiveSearch.index(:byte_probe)

    multibyte = "café" * 15    # 60 characters, 75 bytes
    assert_equal 60, index.store.send(:identifier_size, multibyte) unless postgresql?
    assert_equal 75, index.store.send(:identifier_size, multibyte) if postgresql?

    if postgresql?
      before = Dir.glob(Rails.root.join("db/migrate/*.rb")).size
      assert_raises(Rails::Generators::Error) { generate_document_for(index) }

      assert_equal before, Dir.glob(Rails.root.join("db/migrate/*.rb")).size, "it refused and wrote anyway"
      assert_not ActiveSearch::StoreAdapters::Database::DocumentClass.path_for(index).exist?
    else
      written = generate_document_for(index)
      File.delete(written)
      File.delete(ActiveSearch::StoreAdapters::Database::DocumentClass.path_for(index))
    end
  end

  test "a custom source still defines an index" do
    custom = Class.new do
      def records_for(ids) = []
      def id_for(record) = record.to_s
    end.new

    assert_nothing_raised { ActiveSearch.define_index(:custom_probe, source: custom) { text :title } }
  end

  test "a polymorphic index builds, and its identity fields are emitted once" do
    ActiveSearch.define_index(:poly_build_probe, polymorphic: true) { text :title }
    index = ActiveSearch.index(:poly_build_probe)
    source = index.store.migration_source(index)
    written = nil

    begin
      written = generate_document_for(index)
      Object.class_eval(written.read) # rubocop:disable Security/Eval
      migration = Object.const_get(source.class_name)
      migration.migrate(:up)

      assert_includes index.store.send(:document_connection, index).columns(source.table_name).map(&:name),
        "poly_build_probe_type"
      migration.migrate(:down)
    ensure
      written&.delete if written&.exist?
      ActiveSearch::StoreAdapters::Database::DocumentClass.path_for(index).delete rescue nil
    end
  end

  test "a table name that cannot be written bare is refused, and nothing is written" do
    index = ActiveSearch.index(:creation_probes)
    before = Dir.glob(Rails.root.join("db/migrate/*.rb")).size

    [ "tenant.reviews", "tenant-reviews", "tenant reviews" ].each_with_index do |name, n|
      constant = "BareProbe#{n}Document"
      Object.const_set(constant, Class.new(ApplicationRecord) { self.table_name = name })
      probe = ActiveSearch.define_index(:"bare_probe_#{n}", source: "Article",
        document_class: constant) { text :title }

      assert_raises(Rails::Generators::Error, name) { generate_document_for(probe) }
    ensure
      Object.send(:remove_const, constant) if Object.const_defined?(constant, false)
    end

    assert_equal before, Dir.glob(Rails.root.join("db/migrate/*.rb")).size
  end

  test "a declared field colliding with a derived column is refused" do
    skip "only PostgreSQL derives a companion column" unless postgresql?
    ActiveSearch.define_index(:vector_clash_probe, source: "Article") { text :title; string :title_vector }
    index = ActiveSearch.index(:vector_clash_probe)

    error = assert_raises(Rails::Generators::Error) { generate_document_for(index) }

    assert_match "title_vector", error.message
    assert_match "twice", error.message
  end

  test "revoking removes a class it would have written" do
    model = Rails.root.join("app/models/creation_probe_document.rb")
    kept = File.read(model)
    run_migration(:up)   # the table now exists, so creating would refuse

    begin
      assert_nothing_raised { revoke_generator }
      assert_not File.exist?(model), "revoke must remove the model it wrote"
    ensure
      File.write(model, kept)
    end
  end

  test "the generator refuses a structure that is already there" do
    require "generators/active_search/document/document_generator"
    existing = ActiveSearch.index(:articles)
    assert ActiveRecord::Base.connection.table_exists?("article_documents"),
      "premise: the table must already exist for this to be refused"

    before = article_document_migrations
    generator = ActiveSearch::Generators::DocumentGenerator.new([ "articles" ], [],
      destination_root: Rails.root)
    error = assert_raises(Rails::Generators::Error) { generator.shell.mute { generator.invoke_all } }

    assert_match "already exists", error.message
    assert_equal before, article_document_migrations, "a refusal must leave no migration behind"

    assert_equal({ "articles" => "already built" }, existing.store.create_index(existing).describes)
  end

  test "creating an index writes a migration and names the file it wrote" do
    assert_empty waiting_migrations, "premise: no migration for this index may already be waiting"

    written = generate_document_for(@index)

    assert_equal 1, waiting_migrations.size
    assert_equal waiting_migrations.first, written.to_s
    assert_match "create_table :#{@source.table_name}", File.read(written)
  ensure
    waiting_migrations.each { |path| File.delete(path) }
  end

  test "refuses to write a second migration while one is still waiting" do
    directory = Rails.application.config.paths["db/migrate"].to_a.first
    pending = File.join(directory, "29990101000000_#{@source.file_name}.rb")
    File.write(pending, "# placeholder")

    error = assert_raises(Rails::Generators::Error) { generate_document_for(@index) }

    assert_match "already waiting", error.message
    assert_match "db:migrate", error.message
  ensure
    File.delete(pending) if pending && File.exist?(pending)
  end

  test "a table whose text column has no search index is incompatible, not compatible" do
    skip "SQLite keeps its text in a separate table" if store_adapter_name == :sqlite

    without_search_index = @source.to_ruby.gsub(/^ *(add_index.*fulltext|add_column.*tsvector|add_index.*gin).*\n/, "")
    assert_no_match(/type: :fulltext|:tsvector|using: :gin/, without_search_index,
      "the strip left a search line behind")

    Object.class_eval(without_search_index)
    Object.const_get(@source.class_name).new.migrate(:up)

    verification = ActiveSearch::Schema.verify(@index)

    assert_equal :incompatible, verification.outcome, verification.describe
    assert_includes verification.unmet.map(&:name), "title"
  end

  test "a MySQL migration builds one FULLTEXT index, and a subset search raises against it" do
    skip "only MySQL matches an index by its column list" unless store_adapter_name == :mysql
    index = ActiveSearch.index(:products)
    source = index.store.migration_source(index)
    connection = ActiveRecord::Base.connection

    begin
      connection.drop_table(source.table_name, if_exists: true)
      Object.send(:remove_const, source.class_name) if Object.const_defined?(source.class_name)
      Object.class_eval(source.to_ruby) # rubocop:disable Security/Eval
      Object.const_get(source.class_name).new.migrate(:up)

      built = connection.indexes(source.table_name).select { |i| i.type == :fulltext }.map(&:columns)
      assert_equal [ %w[ name description category ] ], built

      matching = ->(columns) do
        connection.select_value("SELECT COUNT(*) FROM #{source.table_name} " \
          "WHERE MATCH(#{columns}) AGAINST('x' IN BOOLEAN MODE)")
      end

      assert_equal 0, matching.("name, description, category").to_i
      error = assert_raises(ActiveRecord::StatementInvalid) { matching.("name, description") }
      assert_match "FULLTEXT index matching the column list", error.message
    ensure
      connection.drop_table(source.table_name, if_exists: true)
    end
  end

  test "the migration asks for a float wide enough for a Ruby Float" do
    run_migration(:up)
    connection = ActiveRecord::Base.connection
    connection.add_column(@source.table_name, :ratio, :float, limit: 53)

    assert_match "limit: 53", @index.store.migration_source(ActiveSearch.index(:products)).to_ruby

    if store_adapter_name == :mysql
      narrow = connection.columns(@source.table_name).find { |c| c.name == "ratio" }
      assert_equal 53, narrow.limit, "premise: MySQL must report a float width for this to mean anything"
    end
  end

  test "separate FULLTEXT indexes do not satisfy a search over all the text fields" do
    skip "only MySQL matches an index by its column list" unless store_adapter_name == :mysql
    index = ActiveSearch.index(:products)
    source = index.store.migration_source(index)
    connection = ActiveRecord::Base.connection
    table = source.table_name

    begin
      connection.drop_table(table, if_exists: true)
      Object.send(:remove_const, source.class_name) if Object.const_defined?(source.class_name)
      Object.class_eval(source.to_ruby) # rubocop:disable Security/Eval
      Object.const_get(source.class_name).new.migrate(:up)

      assert_equal :compatible, ActiveSearch::Schema.verify(index).outcome,
        "premise: the generated one index over every text column must verify"

      connection.execute("DROP INDEX index_product_documents_on_name_and_description_and_category ON #{table}")
      %w[ name description category ].each do |column|
        connection.execute("CREATE FULLTEXT INDEX zz_#{column} ON #{table} (#{column})")
      end
      index.store.send(:model_for, index).reset_column_information

      verification = ActiveSearch::Schema.verify(index)

      assert_equal :incompatible, verification.outcome, verification.describe
      assert_equal %w[ category description name ], verification.unmet.map(&:name).sort
    ensure
      connection.drop_table(table, if_exists: true)
    end
  end

  test "a MySQL migration says which searches its indexes do not cover" do
    skip "only MySQL matches an index by its column list" unless store_adapter_name == :mysql

    products = ActiveSearch.index(:products)
    ruby = products.store.migration_source(products).to_ruby

    assert_match "searching a subset needs its own index", ruby
    assert_match "name, description, category", ruby
  end

  test "writes for this adapter only, with no branch" do
    ruby = @source.to_ruby

    assert_no_match(/adapter_name|case adapter/, ruby)

    expected = { sqlite: "create_virtual_table", postgresql: ":title_vector, :tsvector",
                 mysql: "type: :fulltext" }.fetch(store_adapter_name)
    assert_match expected, ruby

    ({ sqlite: "tsvector", postgresql: "create_virtual_table",
       mysql: "create_virtual_table" }).each do |adapter, absent|
      assert_no_match(/#{absent}/, ruby) if adapter == store_adapter_name
    end
  end

  test "refuses a declaration it cannot express rather than writing a wrong migration" do
    source = @index.store.migration_source(custom_source_index)

    assert_match "custom source", source.refusal
  end

  test "the document table has a column for a text field only where the adapter stores it there" do
    run_migration(:up)

    columns = ActiveRecord::Base.connection.columns(@source.table_name).map(&:name)
    text = @index.definition.fields.select(&:searchable?).map { |field| field.name.to_s }

    assert text.any?, "premise: the declaration must have a searchable field"
    assert_includes columns, "status", "premise: a non-text column must be there either way"

    if store_adapter_name == :sqlite
      assert_empty columns & text
    else
      assert_equal text.sort, (columns & text).sort
    end
  end

  test "a declared string held in an integer column is incompatible" do
    run_migration(:up)

    assert_equal :compatible, ActiveSearch::Schema.verify(@index).outcome,
      "premise: the migrated table must verify before this changes anything"

    retype_status_to_integer
    @index.store.send(:model_for, @index).reset_column_information

    verification = ActiveSearch::Schema.verify(@index)

    assert_equal :incompatible, verification.outcome, verification.describe
    assert_includes verification.unmet.map(&:name), "status"
  end

  test "a declared string held in a text column is compatible" do
    run_migration(:up)

    assert_equal :compatible, ActiveSearch::Schema.verify(@index).outcome,
      "premise: the migrated table must verify before this changes anything"

    retype_status_to_text
    @index.store.send(:model_for, @index).reset_column_information

    assert_equal :text, ActiveRecord::Base.connection.columns(@source.table_name)
      .find { |c| c.name == "status" }.type, "premise: the column must really be text now"
    assert_equal :compatible, ActiveSearch::Schema.verify(@index).outcome
  end

  test "refuses to write a migration when the database is not answering" do
    unavailable = ActiveSearch::Schema::Inspection.new(state: :unavailable, detail: "connection refused")

    overriding(@index.store, :inspect_schema, ->(_index) { unavailable }) do
      error = assert_raises(ActiveSearch::Schema::CreationRefused) { @index.store.create_index(@index) }

      assert_match "not answering", error.message
      assert_match "connection refused", error.message
    end

    assert_empty Dir.glob(File.join(migration_directory, "*_#{@source.file_name}.rb")),
      "no migration may be left behind by a refused creation"
  end

  test "status explains a refusal instead of naming a command that cannot work" do
    index = custom_source_index
    assert index.store.capabilities.supports_index_creation?, "premise: the store must advertise creation"

    step = ActiveSearch::Schema.next_step_for(index, ActiveSearch::Schema::Verification.missing(index.index_name))

    assert_match "custom source", step
    assert_no_match(/active_search:index:create/, step)
  end

  test "a declared integer in a four-byte column is incompatible" do
    run_migration(:up)

    assert_equal :compatible, ActiveSearch::Schema.verify(@index).outcome,
      "premise: the migrated table must verify before this narrows anything"
    assert_equal 8, account_id_column.limit, "premise: the migration must build eight bytes" if narrowable?

    narrow_account_id
    @index.store.send(:model_for, @index).reset_column_information

    if narrowable?
      assert_equal 4, account_id_column.limit
      assert_equal :incompatible, ActiveSearch::Schema.verify(@index).outcome
    else
      assert_nil account_id_column.limit
      assert_equal :compatible, ActiveSearch::Schema.verify(@index).outcome
    end
  end

  private
    def narrowable?
      %i[ postgresql mysql ].include?(store_adapter_name)
    end

    def account_id_column
      ActiveRecord::Base.connection.columns(@source.table_name).find { |c| c.name == "account_id" }
    end

    def narrow_account_id
      connection = ActiveRecord::Base.connection
      table = @source.table_name

      case store_adapter_name
      when :postgresql then connection.execute("ALTER TABLE #{table} ALTER COLUMN account_id TYPE integer")
      when :mysql then connection.execute("ALTER TABLE #{table} MODIFY account_id INT")
      when :sqlite
        connection.execute("ALTER TABLE #{table} DROP COLUMN account_id")
        connection.execute("ALTER TABLE #{table} ADD COLUMN account_id INTEGER")
      end
    end

    def overriding(object, name, replacement)
      object.define_singleton_method(name, &replacement)
      yield
    ensure
      object.singleton_class.send(:remove_method, name)
    end

    def article_document_migrations
      Dir.glob(File.join(migration_directory, "*_create_article_documents.rb")).sort
    end

    def waiting_migrations
      Dir.glob(File.join(migration_directory, "*_#{@source.file_name}.rb"))
    end

    def migration_directory
      Rails.application.config.paths["db/migrate"].to_a.first
    end

    def retype_status_to_text
      retype_status(postgresql: "text", mysql: "TEXT", sqlite: "TEXT")
    end

    def retype_status_to_integer
      retype_status(postgresql: "integer", mysql: "INT", sqlite: "INTEGER")
    end

    def retype_status(**types)
      connection = ActiveRecord::Base.connection
      table = @source.table_name
      type = types.fetch(store_adapter_name)

      case store_adapter_name
      when :postgresql then connection.execute("ALTER TABLE #{table} ALTER COLUMN status TYPE #{type} USING NULL")
      when :mysql then connection.execute("ALTER TABLE #{table} MODIFY status #{type}")
      when :sqlite
        connection.execute("ALTER TABLE #{table} DROP COLUMN status")
        connection.execute("ALTER TABLE #{table} ADD COLUMN status #{type}")
      end
    end

    def database_adapter?
      %i[ sqlite mysql postgresql ].include?(store_adapter_name)
    end

    def table_exists?
      ActiveRecord::Base.connection.table_exists?(@source.table_name)
    end

    def drop_tables
      connection = ActiveRecord::Base.connection
      connection.execute("DROP TABLE IF EXISTS #{@source.table_name}_fts") if store_adapter_name == :sqlite
      connection.drop_table(@source.table_name, if_exists: true)
    end

    def revoke_generator
      require "generators/active_search/document/document_generator"
      generator = ActiveSearch::Generators::DocumentGenerator.new([ "creation_probes" ], [],
        destination_root: Rails.root, behavior: :revoke)
      generator.shell.mute { generator.invoke_all }
    end

    def custom_source_index
      source = Class.new do
        def records_for(ids) = []
        def id_for(record) = record.to_s
      end.new

      ActiveSearch::Index.new(:custom_source_probe, definition: @index.definition,
        source: source, store_name: @index.store_name)
    end

    def postgresql?
      store_adapter_name == :postgresql
    end

    def run_migration(direction)
      Object.send(:remove_const, @source.class_name) if Object.const_defined?(@source.class_name)
      Object.class_eval(@source.to_ruby) # rubocop:disable Security/Eval
      Object.const_get(@source.class_name).new.migrate(direction)
    end
end
