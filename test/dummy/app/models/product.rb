class Product < ApplicationRecord
  include ActiveSearch::Indexable

  belongs_to :author, optional: true

  has_search serializer: :to_search_document

  def to_search_document
    {
      name: name,
      description: description,
      price: price&.to_f,
      category: category,
      author_name: author&.name
    }
  end
end
