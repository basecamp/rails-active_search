class Author < ApplicationRecord
  include ActiveSearch::Indexable

  has_many :products
end
