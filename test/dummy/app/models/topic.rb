class Topic < ApplicationRecord
  has_search index: :topics
end
