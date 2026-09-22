ActiveSearch.define_index(:articles) do
  text :title
  text :content
  integer :account_id
  string :status
  datetime :published_at
  date :published_on
  boolean :featured
end

ActiveSearch.define_index(:products) do
  text :name
  text :description
  float :price
  text :category
  string :author_name
end

ActiveSearch.define_index(:comments) do
  text :body
  integer :account_id
  integer :article_id
  boolean :approved
  datetime :published_at
end

ActiveSearch.define_index(:records, polymorphic: true, route_by: :account_id) do
  text :title
  text :body
  integer :account_id
end

# Flat id collections beside ordinary single-value fields.
ActiveSearch.define_index(:topics) do
  text :subject
  integer :account_id
  integer :folder_ids, multiple: true
  string :labels, multiple: true
  datetime :seen_at, multiple: true
end

ActiveSearch.define_index(:guarded_articles) do
  text :title
  text :content
end

ActiveSearch.define_index(:unless_guarded_articles) do
  text :title
  text :content
end

ActiveSearch.define_index(:proc_guarded_articles) do
  text :title
  text :content
  string :status
end

ActiveSearch.define_index(:namespaced_tests, source: "Article") do
  text :title
  text :content
end

# Nothing sets this one up. It exists so a test can create an index from nothing and delete it.
ActiveSearch.define_index(:creation_probes, source: "Article") do
  text :title
  string :status
  integer :account_id
end

# A collection of each type a store spells differently, so create-then-verify covers the case where
# an adapter builds one field and expects another.
ActiveSearch.define_index(:collection_probes, source: "Article") do
  text :title
  integer :account_id
  integer :folder_ids, multiple: true
  string :labels, multiple: true
  datetime :seen_at, multiple: true
end

# A field named type, which would make the document table single table inheritance unless the class
# says otherwise. The generator writes that line; the gem cannot add it to a class it does not own.
ActiveSearch.define_index(:sti_probes, source: "Article") do
  text :title
  string :type
end
