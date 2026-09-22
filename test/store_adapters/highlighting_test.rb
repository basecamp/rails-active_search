require "test_helper"

# Every adapter that highlights wraps a match in <mark>, keeping the matched text's own case,
# whatever the engine underneath. MySQL does not highlight at all and raises instead.

class HighlightingTest < ActiveSupport::TestCase
  searches :articles

  setup do
    skip "Adapter does not support highlighting" unless supports_highlighting?
  end

  test "search with highlighting returns exact highlighted title" do
    article = Article.create!(title: "Ruby Programming Guide", content: "Learn basics", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").highlight(true).results
    assert_equal 1, results.total

    result = results.first
    assert_equal "<mark>Ruby</mark> Programming Guide", result.hit.highlight(:title)
  end

  test "search with highlighting returns exact highlighted content" do
    article = Article.create!(title: "Programming Guide", content: "Learn Ruby basics", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").highlight(true).results
    assert_equal 1, results.total

    result = results.first
    assert_equal "Learn <mark>Ruby</mark> basics", result.hit.highlight(:content)
  end

  test "search with highlighting highlights all occurrences in title" do
    skip "Manticore highlights a phrase as one block, not word by word" if store_adapter_name == :manticore

    article = Article.create!(title: "Ruby Ruby Ruby", content: "Content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").highlight(true).results
    result = results.first

    assert_equal "<mark>Ruby</mark> <mark>Ruby</mark> <mark>Ruby</mark>", result.hit.highlight(:title)
  end

  test "search with highlighting highlights all occurrences in content" do
    article = Article.create!(title: "Guide", content: "Ruby is great and Ruby is fun", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").highlight(true).results
    result = results.first

    assert_equal "<mark>Ruby</mark> is great and <mark>Ruby</mark> is fun", result.hit.highlight(:content)
  end

  test "search with highlighting preserves original case" do
    article = Article.create!(title: "RUBY and ruby and Ruby", content: "Content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("ruby").highlight(true).results
    result = results.first

    assert_equal "<mark>RUBY</mark> and <mark>ruby</mark> and <mark>Ruby</mark>", result.hit.highlight(:title)
  end

  test "search with highlighting on both fields" do
    article = Article.create!(title: "Ruby Guide", content: "Learn Ruby now", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").highlight(true).results
    result = results.first

    assert_equal "<mark>Ruby</mark> Guide", result.hit.highlight(:title)
    assert_equal "Learn <mark>Ruby</mark> now", result.hit.highlight(:content)
  end

  test "search without highlighting returns empty highlights hash" do
    article = Article.create!(title: "Ruby Programming", content: "Learn Ruby basics", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").results
    assert_equal 1, results.total

    result = results.first
    assert_equal({}, result.hit.highlights)
    assert_nil result.hit.highlight(:title)
    assert_nil result.hit.highlight(:content)
  end

  test "search with highlighting and no matches returns no results" do
    article = Article.create!(title: "Python Guide", content: "Learn Python basics", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").highlight(true).results
    assert_equal 0, results.total
  end

  test "highlight returns nil for non-existent field" do
    article = Article.create!(title: "Ruby Guide", content: "Content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").highlight(true).results
    result = results.first

    assert_nil result.hit.highlight(:nonexistent)
  end

  test "a field that matched nothing has no highlight, whatever the store returned" do
    article = Article.create!(title: "Ruby Guide", content: "No match here", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    hit = ActiveSearch.index(:articles).search("Ruby").highlight(true).results.first.hit

    assert_equal "<mark>Ruby</mark> Guide", hit.highlight(:title)
    assert_nil hit.highlight(:content)
    assert_not_includes hit.highlights.keys, :content, "an absent highlight is absent, not nil-valued"
  end

  test "highlights returns hash keyed by field symbol" do
    article = Article.create!(title: "Ruby Guide", content: "Ruby content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").highlight(true).results
    result = results.first

    assert result.hit.highlights.key?(:title), "Highlights should have :title key"
    assert result.hit.highlights.key?(:content), "Highlights should have :content key"
  end

  test "highlighting escapes HTML in title to prevent XSS" do
    article = Article.create!(title: "<script>alert(1)</script> Ruby", content: "Content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").highlight(true).results
    result = results.first

    title_hl = result.hit.highlight(:title)
    assert_includes title_hl, "&lt;script&gt;"
    assert_includes title_hl, "&lt;/script&gt;"
    assert_includes title_hl, "<mark>Ruby</mark>"
    refute_includes title_hl, "<script>"
  end

  test "highlighting escapes HTML in content to prevent XSS" do
    article = Article.create!(title: "Guide", content: "<img onerror='alert(1)'> Ruby rocks", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").highlight(true).results
    result = results.first

    content_hl = result.hit.highlight(:content)
    assert_includes content_hl, "&lt;img"
    assert_includes content_hl, "<mark>Ruby</mark>"
    refute_includes content_hl, "<img"
  end

  test "highlighting preserves ampersands and special characters" do
    article = Article.create!(title: "Ruby & Rails", content: "Content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").highlight(true).results
    result = results.first

    assert_equal "<mark>Ruby</mark> &amp; Rails", result.hit.highlight(:title)
  end

  test "highlighting escapes angle brackets in search results" do
    article = Article.create!(title: "Use Ruby for <templates>", content: "Content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").highlight(true).results
    result = results.first

    assert_equal "Use <mark>Ruby</mark> for &lt;templates&gt;", result.hit.highlight(:title)
  end

  test "highlight with format: :text does not escape HTML" do
    article = Article.create!(title: "<b>Bold</b> Ruby", content: "Content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").highlight(title: { format: :text }).results
    result = results.first

    title_hl = result.hit.highlight(:title)
    assert_equal "<b>Bold</b> <mark>Ruby</mark>", title_hl
  end

  test "highlight with custom markers" do
    article = Article.create!(title: "Ruby Programming", content: "Content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").highlight(title: { markers: [ "<em>", "</em>" ] }).results
    result = results.first

    assert_equal "<em>Ruby</em> Programming", result.hit.highlight(:title)
  end

  test "highlight with custom markers and html format escapes HTML" do
    article = Article.create!(title: "<script>x</script> Ruby", content: "Content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").highlight(title: { markers: [ "<em>", "</em>" ] }).results
    result = results.first

    title_hl = result.hit.highlight(:title)
    assert_equal "&lt;script&gt;x&lt;/script&gt; <em>Ruby</em>", title_hl
  end

  test "highlight with custom markers and text format does not escape HTML" do
    article = Article.create!(title: "<b>Bold</b> Ruby", content: "Content", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").highlight(title: { markers: [ "**", "**" ], format: :text }).results
    result = results.first

    assert_equal "<b>Bold</b> **Ruby**", result.hit.highlight(:title)
  end

  test "highlight with complex HTML markers" do
    article = Article.create!(title: "Ruby Guide", content: "Learn Ruby", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").highlight(
      title: { markers: [ '<mark class="highlight"><span>', "</span></mark>" ] },
      content: { markers: [ '<mark class="highlight"><span>', "</span></mark>" ] }
    ).results
    result = results.first

    assert_equal '<mark class="highlight"><span>Ruby</span></mark> Guide', result.hit.highlight(:title)
    assert_equal 'Learn <mark class="highlight"><span>Ruby</span></mark>', result.hit.highlight(:content)
  end

  test "highlight specific fields only" do
    article = Article.create!(title: "Ruby Guide", content: "Learn Ruby basics", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").highlight(title: true).results
    result = results.first

    assert_equal "<mark>Ruby</mark> Guide", result.hit.highlight(:title)
    assert_nil result.hit.highlight(:content), "content was not among the requested fields"
  end

  test "highlight multiple specific fields" do
    article = Article.create!(title: "Ruby Guide", content: "Learn Ruby basics", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").highlight(title: true, content: true).results
    result = results.first

    assert_equal "<mark>Ruby</mark> Guide", result.hit.highlight(:title)
    assert_equal "Learn <mark>Ruby</mark> basics", result.hit.highlight(:content)
  end

  test "highlight with per-field markers" do
    skip "Adapter does not support per-field markers" unless supports_highlight_per_field_markers?

    article = Article.create!(title: "Ruby Guide", content: "Learn Ruby basics", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").highlight(
      title: { markers: [ "<strong>", "</strong>" ] },
      content: { markers: [ "<em>", "</em>" ] }
    ).results
    result = results.first

    assert_equal "<strong>Ruby</strong> Guide", result.hit.highlight(:title)
    assert_equal "Learn <em>Ruby</em> basics", result.hit.highlight(:content)
  end

  test "raises when per-field markers are requested on unsupported adapters" do
    skip "Adapter supports per-field markers" if supports_highlight_per_field_markers?

    article = Article.create!(title: "Ruby Guide", content: "Learn Ruby basics", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    assert_raises(ActiveSearch::UnsupportedOperationError) do
      ActiveSearch.index(:articles).search("Ruby").highlight(
        title: { markers: [ "<strong>", "</strong>" ] },
        content: { markers: [ "<em>", "</em>" ] }
      ).results
    end
  end

  test "raises when per-field snippet sizes are requested on unsupported adapters" do
    if !supports_snippet_unit?(:characters) && !supports_snippet_unit?(:words)
      skip "Adapter does not support snippets"
    end
    skip "Adapter supports per-field snippet sizes" if supports_highlight_per_field_snippets?

    long_content = ("word " * 30) + "Ruby programming" + (" word" * 30)
    article = Article.create!(title: "Ruby Guide", content: long_content, account_id: 1)
    ActiveSearch.index(:articles).add(article)

    first_snippet = if supports_snippet_unit?(:characters)
      { characters: 40 }
    else
      { words: 8 }
    end
    second_snippet = if supports_snippet_unit?(:characters)
      { characters: 80 }
    else
      { words: 14 }
    end

    assert_raises(ActiveSearch::UnsupportedOperationError) do
      ActiveSearch.index(:articles).search("Ruby").highlight(
        title: { snippet: first_snippet },
        content: { snippet: second_snippet }
      ).results
    end
  end

  test "raises when one field asks for a snippet and another asks for none on unsupported adapters" do
    if !supports_snippet_unit?(:characters) && !supports_snippet_unit?(:words)
      skip "Adapter does not support snippets"
    end
    skip "Adapter supports per-field snippet sizes" if supports_highlight_per_field_snippets?

    long_content = ("word " * 30) + "Ruby programming" + (" word" * 30)
    article = Article.create!(title: "Ruby Guide", content: long_content, account_id: 1)
    ActiveSearch.index(:articles).add(article)

    snippet = supports_snippet_unit?(:characters) ? { characters: 40 } : { words: 8 }

    assert_raises(ActiveSearch::UnsupportedOperationError) do
      ActiveSearch.index(:articles).search("Ruby").highlight(
        title: true,
        content: { snippet: snippet }
      ).results
    end
  end

  test "a snippet on one field of several is sized as asked and leaves the others whole" do
    skip "Adapter does not support per-field snippet sizes" unless supports_highlight_per_field_snippets?

    long_content = ("alpha " * 60) + "Ruby programming" + (" omega" * 60)
    article = Article.create!(title: "Ruby Guide", content: long_content, account_id: 1)
    ActiveSearch.index(:articles).add(article)

    small, large = if supports_snippet_unit?(:characters)
      [ { characters: 30 }, { characters: 300 } ]
    else
      [ { words: 4 }, { words: 40 } ]
    end

    highlights = ->(snippet) {
      hit = ActiveSearch.index(:articles).search("Ruby").highlight(
        title: true,
        content: { snippet: snippet }
      ).results.first.hit
      [ hit.highlight(:title), hit.highlight(:content) ]
    }

    small_title, small_content = highlights.call(small)
    large_title, large_content = highlights.call(large)

    assert_operator small_content.length, :<, large_content.length
    assert_operator large_content.length, :<, long_content.length
    assert_equal "<mark>Ruby</mark> Guide", small_title
    assert_equal "<mark>Ruby</mark> Guide", large_title
  end

  test "highlight(false) explicitly disables highlighting" do
    article = Article.create!(title: "Ruby Guide", content: "Learn Ruby basics", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby").highlight(true).highlight(false).results
    result = results.first

    assert_equal({}, result.hit.highlights)
    assert_nil result.hit.highlight(:title)
  end

  test "highlight chaining overwrites previous options" do
    article = Article.create!(title: "Ruby Guide", content: "Learn Ruby basics", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search("Ruby")
      .highlight(title: { markers: [ "<em>", "</em>" ] })
      .highlight(title: { markers: [ "<strong>", "</strong>" ] })
      .results
    result = results.first

    assert_equal "<strong>Ruby</strong> Guide", result.hit.highlight(:title)
  end

  test "a filter narrows the results and the survivors are still highlighted" do
    article1 = Article.create!(title: "Ruby Guide", content: "Learn basics", account_id: 1)
    article2 = Article.create!(title: "Ruby Tutorial", content: "Advanced topics", account_id: 2)
    ActiveSearch.index(:articles).add(article1)
    ActiveSearch.index(:articles).add(article2)

    results = ActiveSearch.index(:articles).search("Ruby").filter(account_id: 1).highlight(true).results

    assert_equal 1, results.total
    assert_equal "<mark>Ruby</mark> Guide", results.first.hit.highlight(:title)
  end

  test "a sort orders the results and each one is still highlighted" do
    article1 = Article.create!(title: "Ruby Guide A", content: "Content", account_id: 1)
    article2 = Article.create!(title: "Ruby Guide B", content: "Content", account_id: 2)
    ActiveSearch.index(:articles).add(article1)
    ActiveSearch.index(:articles).add(article2)

    results = ActiveSearch.index(:articles).search("Ruby").sort(account_id: :desc).highlight(true).results

    assert_equal 2, results.total
    assert_equal "<mark>Ruby</mark> Guide B", results.first.hit.highlight(:title)
    assert_equal "<mark>Ruby</mark> Guide A", results.to_a.last.hit.highlight(:title)
  end

  test "a page cut by limit and offset highlights every hit on it" do
    3.times do |i|
      Article.create!(title: "Ruby Article #{i}", content: "Content", account_id: i + 1).tap { |a| ActiveSearch.index(:articles).add(a) }
    end

    results = ActiveSearch.index(:articles).search("Ruby").highlight(true).limit(2).offset(1).results

    assert_equal 2, results.to_a.size
    results.each do |result|
      assert_includes result.hit.highlight(:title), "<mark>Ruby</mark>"
    end
  end

  test "a phrase query marks the phrase, whole or word by word" do
    skip "Adapter does not support phrase queries" unless supports_phrase_search?

    article = Article.create!(title: "Ruby Programming Guide", content: "Learn Ruby on Rails", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).search('"Ruby Programming"').highlight(true).results
    assert_equal 1, results.total

    result = results.first
    title_hl = result.hit.highlight(:title)
    assert title_hl.include?("<mark>Ruby Programming</mark>") ||
           (title_hl.include?("<mark>Ruby</mark>") && title_hl.include?("<mark>Programming</mark>")),
           "Expected phrase to be highlighted, got: #{title_hl}"
  end

  test "narrowing the searched fields highlights the field that was asked for, not its neighbour" do
    article = Article.create!(title: "Zanzibar shipping", content: "Two companies shipped wolves",
      account_id: 1)
    ActiveSearch.index(:articles).add(article)

    hit = ActiveSearch.index(:articles).search("companies", fields: [ :content ]).highlight(true)
      .results.first.hit

    assert_equal "Two <mark>companies</mark> shipped wolves", hit.highlight(:content)
  end

  test "an unknown highlight option is refused rather than dropped" do
    error = assert_raises(ActiveSearch::QueryError) do
      ActiveSearch.index(:articles).search("Ruby").highlight(title: { type: "plain" })
    end

    assert_match(/Unknown highlight option :type/, error.message)
    assert_match(/format, markers, snippet/, error.message)
  end

  test "several unknown options are named together" do
    error = assert_raises(ActiveSearch::QueryError) do
      ActiveSearch.index(:articles).search("Ruby").highlight(title: { type: "plain", boundary: 20 })
    end

    assert_match(/Unknown highlight options :type, :boundary/, error.message)
  end

  test "a backend option that has an equivalent is redirected to it by name" do
    error = assert_raises(ActiveSearch::QueryError) do
      ActiveSearch.index(:articles).search("Ruby").highlight(title: { pre_tags: [ "<em>" ] })
    end

    assert_match(/Use markers for pre_tags\./, error.message)
  end

  test "keys sharing an equivalent are named together" do
    error = assert_raises(ActiveSearch::QueryError) do
      ActiveSearch.index(:articles).search("Ruby")
        .highlight(title: { pre_tags: [ "<em>" ], post_tags: [ "</em>" ], fragment_size: 30 })
    end

    assert_match(/Use markers for pre_tags and post_tags\./, error.message)
    assert_match(/Use snippet for fragment_size\./, error.message)
  end

  test "an option with no equivalent is redirected to native" do
    error = assert_raises(ActiveSearch::QueryError) do
      ActiveSearch.index(:articles).search("Ruby").highlight(title: { type: "plain" })
    end

    assert_match(/through native/, error.message)
    assert_no_match(/Use \w+ for type/, error.message)
  end

  test "a string key is recognised the same as a symbol" do
    options = ActiveSearch::Highlighting::FieldOptions.new(
      "format" => :text, "markers" => [ "[", "]" ], "snippet" => { "words" => 5 })

    assert_equal :text, options.format
    assert_equal [ "[", "]" ], [ options.open_marker, options.close_marker ]
    assert_equal :words, options.snippet_unit
    assert_equal 5, options.snippet_value
  end

  test "field names given as strings key the highlights the same as symbols" do
    article = Article.create!(title: "Ruby Guide", content: "Learn Ruby basics", account_id: 1)
    ActiveSearch.index(:articles).add(article)

    hit = ActiveSearch.index(:articles).search("Ruby", fields: %w[ title content ]).highlight(true)
      .results.first.hit

    assert_equal "<mark>Ruby</mark> Guide", hit.highlight(:title)
  end

  test "a filter-only query with highlighting yields no marks rather than erroring" do
    article = Article.create!(title: "FilterOnlyHl", content: "text", account_id: 78)
    ActiveSearch.index(:articles).add(article)

    results = ActiveSearch.index(:articles).filter(account_id: 78).highlight(true).results

    assert_equal [ article.id ], results.map(&:id)
  end
end
