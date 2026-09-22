class CreateGuardedArticles < ActiveRecord::Migration[7.0]
  def change
    create_table :guarded_article do |t|
      t.string :title
      t.text :content
      t.boolean :should_index, default: true
      t.timestamps
    end

    create_table :unless_guarded_article do |t|
      t.string :title
      t.text :content
      t.boolean :skip_indexing, default: false
      t.timestamps
    end

    create_table :proc_guarded_article do |t|
      t.string :title
      t.text :content
      t.string :status, default: "draft"
      t.timestamps
    end
  end
end
