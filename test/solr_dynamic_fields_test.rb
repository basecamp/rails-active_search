require "test_helper"

class SolrDynamicFieldsTest < ActiveSupport::TestCase
  searches :articles

  def store = ActiveSearch.index(:articles).store

  test "a declared name matching a dynamicField pattern is observed, not stripped" do
    skip "Solr-only behavior" unless store_adapter_name == :solr

    probe = ActiveSearch.define_index(:solr_dynamic_probe, source: "Topic") do
      text :body_txt
      integer :account_id
    end
    def probe.index_name = :articles # a core carrying the _default *_txt dynamic rules

    names = store.send(:observe_index, probe).map(&:name)

    assert_includes names, "body_txt", "the *_txt dynamic rule serves body_txt"
    assert_includes names, "account_id", "explicit fields are still observed"
  end

  test "dynamic_match requires the literal part of the pattern to line up exactly" do
    skip "Solr-only behavior" unless store_adapter_name == :solr

    assert store.send(:dynamic_match?, "*_txt", "body_txt")
    assert store.send(:dynamic_match?, "attr_*", "attr_color")
    assert_not store.send(:dynamic_match?, "*_txt", "body_str")
    assert_not store.send(:dynamic_match?, "attr_*", "color_attr")
    assert store.send(:dynamic_match?, "exact", "exact")
  end
end
