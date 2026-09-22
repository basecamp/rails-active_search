class AddPublishedOnToArticleDocuments < ActiveRecord::Migration[7.0]
  def change
    add_column :article_documents, :published_on, :date
  end
end
