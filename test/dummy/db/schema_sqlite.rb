# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2024_01_01_000019) do
  create_table "admin_documents", force: :cascade do |t|
    t.bigint "account_id"
    t.text "body"
    t.datetime "created_at", null: false
    t.string "title"
    t.datetime "updated_at", null: false
  end

  create_table "article_documents", force: :cascade do |t|
    t.bigint "account_id"
    t.string "article_id", null: false
    t.text "content"
    t.boolean "featured"
    t.datetime "published_at"
    t.date "published_on"
    t.string "status"
    t.text "title"
    t.index ["article_id"], name: "index_article_documents_on_article_id", unique: true
  end

  create_table "articles", force: :cascade do |t|
    t.bigint "account_id"
    t.text "content"
    t.datetime "created_at", null: false
    t.boolean "featured", default: false
    t.bigint "priority"
    t.datetime "published_at"
    t.string "status", default: "published"
    t.string "title"
    t.datetime "updated_at", null: false
  end

  create_table "authors", force: :cascade do |t|
    t.string "bio"
    t.datetime "created_at", null: false
    t.string "email"
    t.string "name"
    t.datetime "updated_at", null: false
  end

  create_table "comment_documents", force: :cascade do |t|
    t.bigint "account_id"
    t.boolean "approved"
    t.bigint "article_id"
    t.text "body"
    t.string "comment_id", null: false
    t.datetime "published_at"
    t.index ["comment_id"], name: "index_comment_documents_on_comment_id", unique: true
  end

  create_table "comments", force: :cascade do |t|
    t.bigint "account_id"
    t.boolean "approved", default: false
    t.bigint "article_id"
    t.text "body"
    t.datetime "created_at", null: false
    t.datetime "published_at"
    t.datetime "updated_at", null: false
  end

  create_table "guarded_article", force: :cascade do |t|
    t.text "content"
    t.datetime "created_at", null: false
    t.boolean "should_index", default: true
    t.string "title"
    t.datetime "updated_at", null: false
  end

  create_table "guarded_article_documents", force: :cascade do |t|
    t.text "content"
    t.string "guarded_article_id", null: false
    t.text "title"
    t.index ["guarded_article_id"], name: "index_guarded_article_documents_on_guarded_article_id", unique: true
  end

  create_table "pages", force: :cascade do |t|
    t.bigint "account_id"
    t.text "content"
    t.datetime "created_at", null: false
    t.string "status", default: "published"
    t.string "title"
    t.datetime "updated_at", null: false
  end

  create_table "posts", force: :cascade do |t|
    t.bigint "account_id"
    t.text "body"
    t.datetime "created_at", null: false
    t.string "headline"
    t.string "status", default: "published"
    t.datetime "updated_at", null: false
  end

  create_table "proc_guarded_article", force: :cascade do |t|
    t.text "content"
    t.datetime "created_at", null: false
    t.string "status", default: "draft"
    t.string "title"
    t.datetime "updated_at", null: false
  end

  create_table "proc_guarded_article_documents", force: :cascade do |t|
    t.text "content"
    t.string "proc_guarded_article_id", null: false
    t.string "status"
    t.text "title"
    t.index ["proc_guarded_article_id"], name: "idx_proc_guarded_article_docs_on_id", unique: true
  end

  create_table "products", force: :cascade do |t|
    t.bigint "author_id"
    t.string "category"
    t.datetime "created_at", null: false
    t.text "description"
    t.string "name"
    t.decimal "price", precision: 10, scale: 2
    t.datetime "updated_at", null: false
    t.index ["author_id"], name: "index_products_on_author_id"
  end

  create_table "record_documents", force: :cascade do |t|
    t.bigint "account_id"
    t.text "body"
    t.string "record_id", null: false
    t.string "record_type", null: false
    t.text "title"
    t.index ["record_type", "record_id"], name: "index_record_documents_on_record_type_and_record_id", unique: true
  end

  create_table "search_namespaced_test_documents", force: :cascade do |t|
    t.string "article_id", null: false
    t.text "content"
    t.text "title"
    t.index ["article_id"], name: "index_search_namespaced_test_documents_on_article_id", unique: true
  end

  create_table "topic_documents", force: :cascade do |t|
    t.bigint "account_id"
    t.json "folder_ids"
    t.json "labels"
    t.json "seen_at"
    t.text "subject"
    t.string "topic_id", null: false
    t.index ["topic_id"], name: "index_topic_documents_on_topic_id", unique: true
  end

  create_table "topics", force: :cascade do |t|
    t.bigint "account_id"
    t.json "folder_ids"
    t.json "labels"
    t.json "seen_at"
    t.string "subject"
  end

  create_table "unless_guarded_article", force: :cascade do |t|
    t.text "content"
    t.datetime "created_at", null: false
    t.boolean "skip_indexing", default: false
    t.string "title"
    t.datetime "updated_at", null: false
  end

  create_table "unless_guarded_article_documents", force: :cascade do |t|
    t.text "content"
    t.text "title"
    t.string "unless_guarded_article_id", null: false
    t.index ["unless_guarded_article_id"], name: "idx_unless_guarded_article_docs_on_id", unique: true
  end

  add_foreign_key "products", "authors"

  # Virtual tables defined in this database.
  # Note that virtual tables may not work with other database engines. Be careful if changing database.
  create_virtual_table "article_documents_fts", "fts5", ["title", "content"]
  create_virtual_table "comment_documents_fts", "fts5", ["body"]
  create_virtual_table "guarded_article_documents_fts", "fts5", ["title", "content"]
  create_virtual_table "proc_guarded_article_documents_fts", "fts5", ["title", "content"]
  create_virtual_table "record_documents_fts", "fts5", ["title", "body"]
  create_virtual_table "search_namespaced_test_documents_fts", "fts5", ["title", "content"]
  create_virtual_table "topic_documents_fts", "fts5", ["subject"]
  create_virtual_table "unless_guarded_article_documents_fts", "fts5", ["title", "content"]
end
