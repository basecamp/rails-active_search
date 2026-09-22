require "test_helper"

class SchemaStatusTest < ActiveSupport::TestCase
  searches :articles

  setup { @index = ActiveSearch.index(:articles) }

  test "a built index reports how many documents it holds" do
    Article.create!(title: "Counted", content: "Body", status: "live", account_id: 1)
      .tap { |article| @index.add(article) }
    @index.store.refresh(:articles) rescue nil

    verification = ActiveSearch::Schema.verify(@index)

    assert_equal 1, ActiveSearch::Schema.population_of(@index, verification)
  end

  test "a missing index counts nothing rather than guessing zero" do
    probe = ActiveSearch.index(:creation_probes)
    verification = ActiveSearch::Schema.verify(probe)

    assert_equal :not_applicable, ActiveSearch::Schema.population_of(probe, verification)
  end

  test "a missing index names the command that builds it" do
    probe = ActiveSearch.index(:creation_probes)
    step = ActiveSearch::Schema.next_step_for(probe, ActiveSearch::Schema.verify(probe))

    if %i[ sqlite mysql postgresql ].include?(store_adapter_name)
      assert_equal "rails generate active_search:document creation_probes, then rails db:migrate", step
    elsif probe.store.capabilities.supports_index_creation?
      assert_equal "rails active_search:index:create INDEX=creation_probes", step
    else
      assert_match "Create it in the store", step
    end
  end

  test "a built index suggests nothing, because there is nothing to do" do
    assert_nil ActiveSearch::Schema.next_step_for(@index, ActiveSearch::Schema.verify(@index))
  end

  test "a store that cannot build an index says so instead of naming a command" do
    bare = index_on(ActiveSearch::StoreAdapters::Base.new)
    step = ActiveSearch::Schema.next_step_for(bare, ActiveSearch::Schema.verify(bare))

    assert_match "Create it in the store", step
    assert_no_match(/index:create/, step)
  end

  test "a store that hangs is reported as unavailable rather than hanging the command" do
    slow = Class.new(ActiveSearch::StoreAdapters::Base) do
      def schema_requirements(_index) = sleep(5) || []
      def inspect_schema(_index) = ActiveSearch::Schema::Inspection.new(state: :missing)
    end.new

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    verification = ActiveSearch::Schema.verify(index_on(slow), timeout: 0.2)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_equal :unavailable, verification.outcome
    assert_match "did not answer", verification.describe
    assert_operator elapsed, :<, 2, "it waited for the store instead of giving up"
  end

  test "an adapter class with no name does not break the report" do
    assert_equal "adapter", ActiveSearch::Schema.store_label(index_on(Class.new(ActiveSearch::StoreAdapters::Base).new))
  end

  test "the command status prints names the index the registry answers to" do
    skip "#{store_adapter_name} names no create command" unless capabilities.supports_index_creation?
    ActiveSearch.define_index(:status_alias, source: "Article", index_name: :status_physical) { text :title }
    index = ActiveSearch.index(:status_alias)

    step = ActiveSearch::Schema.next_step_for(index, ActiveSearch::Schema::Verification.missing(index.index_name))

    assert_match(/\bstatus_alias\b/, step)
    assert_no_match(/status_physical/, step)
  end

  private
    def index_on(store)
      Struct.new(:name, :index_name, :definition, :source, :store, :document_class) do
        def document_class_name = document_class || "#{name.to_s.classify}Document"
        def index_name_for(_store) = index_name
      end
        .new(@index.name, @index.index_name, @index.definition, @index.source, store, nil)
    end
end
