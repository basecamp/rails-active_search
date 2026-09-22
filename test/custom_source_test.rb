require "test_helper"

class CustomSourceTest < ActiveSupport::TestCase
  test "an object answering neither contract method is not accepted as a source" do
    partial = Object.new
    def partial.records_for(ids) = []

    error = assert_raises(ActiveSearch::ConfigurationError) do
      ActiveSearch.define_index(:partial_source_test, source: partial) { text :title }
    end

    assert_match(/Invalid source/, error.message)
  end

  class Card
    include ActiveSearch::Resultable

    attr_reader :id, :title

    def initialize(id:, title:)
      @id = id
      @title = title
    end
  end

  class CardSource
    def initialize(cards)
      @cards = cards.index_by { |card| card.id.to_s }
    end

    def records_for(ids)
      @cards.values_at(*ids.map(&:to_s)).compact
    end

    def id_for(record)
      record.id.to_s
    end

    def identity_attributes_for(record)
      {}
    end

    def type_filter_for(model_class)
      {}
    end

    def storage_key(id)
      { card_id: id }
    end
  end

  def cards
    @cards ||= [ Card.new(id: 1, title: "First card"), Card.new(id: 2, title: "Second card") ]
  end

  def results_for(raw_results, source)
    ActiveSearch::Results.new(raw_results,
      total: raw_results.size,
      definition: ActiveSearch.index(:articles).definition,
      source: source)
  end

  def raw_row(card, score: 1.0, highlights: {})
    { id: card.id.to_s, score: score, fields: { title: card.title }, highlights: highlights }
  end

  test "a custom source hydrates its own objects" do
    results = results_for(cards.map { |card| raw_row(card) }, CardSource.new(cards))

    assert_equal [ "First card", "Second card" ], results.map(&:title)
    assert_equal 2, results.total
  end

  test "an object including Resultable receives its hit" do
    row = raw_row(cards.first, score: 4.5, highlights: { title: "<mark>First</mark> card" })
    result = results_for([ row ], CardSource.new(cards)).first

    assert_equal 4.5, result.hit.score
    assert_equal "First card", result.hit.fields[:title]
    assert_equal "<mark>First</mark> card", result.hit.highlight(:title)
  end

  test "an object without Resultable cannot be hydrated" do
    bare = Class.new do
      attr_reader :id

      def initialize(id)
        @id = id
      end
    end.new(1)

    source = CardSource.new([])
    source.instance_variable_set(:@cards, { "1" => bare })

    assert_raises(NoMethodError) { results_for([ { id: "1", score: 1.0, fields: {}, highlights: {} } ], source).to_a }
  end

  test "hit is nil on an object that did not come from a search" do
    assert_nil Card.new(id: 3, title: "Never searched").hit
  end

  class IntegerIdCardSource < CardSource
    def id_for(record)
      record.id
    end
  end

  test "a source whose id_for returns integers hydrates every record instead of dropping them" do
    results = results_for(cards.map { |card| raw_row(card) }, IntegerIdCardSource.new(cards))

    assert_equal [ "First card", "Second card" ], results.map(&:title)
    assert_equal 0, results.dropped
  end
end
