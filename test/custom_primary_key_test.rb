require "test_helper"

class CustomPrimaryKeyTest < ActiveSupport::TestCase
  class Widget < ApplicationRecord
    self.table_name = "custom_pk_widgets"
    self.primary_key = "uuid"
  end

  setup do
    ApplicationRecord.connection.create_table :custom_pk_widgets, id: false, force: true do |t|
      t.string :uuid, null: false
      t.string :title
    end
  end

  teardown do
    ApplicationRecord.connection.drop_table :custom_pk_widgets, if_exists: true
  end

  test "hydration queries the model's primary key" do
    widget = Widget.create!(uuid: "w-1", title: "Widget")
    source = ActiveSearch::Source::Record.new(name: :custom_pk_widgets,
      source_class_name: "CustomPrimaryKeyTest::Widget")

    assert_equal [ widget ], source.records_for([ "w-1" ])
  end
end
