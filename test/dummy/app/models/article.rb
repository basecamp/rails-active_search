class Article < ApplicationRecord
  has_many :comments

  enum :priority, [ :low, :medium, :high ]

  has_search default: true
  has_search index: :namespaced_tests

  # The :articles index declares a date field; the day of publication stands in for a column.
  def published_on
    published_at&.to_date
  end
end
