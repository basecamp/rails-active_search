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
  create_table "admin_documents", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "account_id"
    t.text "body"
    t.datetime "created_at", null: false
    t.string "title"
    t.datetime "updated_at", null: false
  end

  create_table "article_documents", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "account_id"
    t.string "article_id", null: false
    t.text "content"
    t.boolean "featured"
    t.datetime "published_at"
    t.date "published_on"
    t.string "status"
    t.text "title"
    t.index ["article_id"], name: "index_article_documents_on_article_id", unique: true
    t.index ["content"], name: "index_article_documents_on_content", type: :fulltext
    t.index ["title", "content"], name: "index_article_documents_on_title_and_content", type: :fulltext
    t.index ["title"], name: "index_article_documents_on_title", type: :fulltext
  end

  create_table "articles", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
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

  create_table "authors", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "bio"
    t.datetime "created_at", null: false
    t.string "email"
    t.string "name"
    t.datetime "updated_at", null: false
  end

  create_table "comment_documents", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "account_id"
    t.boolean "approved"
    t.bigint "article_id"
    t.text "body"
    t.string "comment_id", null: false
    t.datetime "published_at"
    t.index ["body"], name: "index_comment_documents_on_body", type: :fulltext
    t.index ["comment_id"], name: "index_comment_documents_on_comment_id", unique: true
  end

  create_table "comments", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "account_id"
    t.boolean "approved", default: false
    t.bigint "article_id"
    t.text "body"
    t.datetime "created_at", null: false
    t.datetime "published_at"
    t.datetime "updated_at", null: false
  end

  create_table "guarded_article", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.text "content"
    t.datetime "created_at", null: false
    t.boolean "should_index", default: true
    t.string "title"
    t.datetime "updated_at", null: false
  end

  create_table "guarded_article_documents", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.text "content"
    t.string "guarded_article_id", null: false
    t.text "title"
    t.index ["guarded_article_id"], name: "index_guarded_article_documents_on_guarded_article_id", unique: true
    t.index ["title", "content"], name: "index_guarded_article_documents_on_title_and_content", type: :fulltext
  end

  create_table "pages", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "account_id"
    t.text "content"
    t.datetime "created_at", null: false
    t.string "status", default: "published"
    t.string "title"
    t.datetime "updated_at", null: false
  end

  create_table "posts", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "account_id"
    t.text "body"
    t.datetime "created_at", null: false
    t.string "headline"
    t.string "status", default: "published"
    t.datetime "updated_at", null: false
  end

  create_table "proc_guarded_article", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.text "content"
    t.datetime "created_at", null: false
    t.string "status", default: "draft"
    t.string "title"
    t.datetime "updated_at", null: false
  end

  create_table "proc_guarded_article_documents", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.text "content"
    t.string "proc_guarded_article_id", null: false
    t.string "status"
    t.text "title"
    t.index ["proc_guarded_article_id"], name: "idx_proc_guarded_article_docs_on_id", unique: true
    t.index ["title", "content"], name: "index_proc_guarded_article_documents_on_title_and_content", type: :fulltext
  end

  create_table "products", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "author_id"
    t.string "category"
    t.datetime "created_at", null: false
    t.text "description"
    t.string "name"
    t.decimal "price", precision: 10, scale: 2
    t.datetime "updated_at", null: false
    t.index ["author_id"], name: "index_products_on_author_id"
  end

  create_table "record_documents", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "account_id"
    t.text "body"
    t.string "record_id", null: false
    t.string "record_type", null: false
    t.text "title"
    t.index ["record_type", "record_id"], name: "index_record_documents_on_record_type_and_record_id", unique: true
    t.index ["title", "body"], name: "index_record_documents_on_title_and_body", type: :fulltext
  end

  create_table "search_namespaced_test_documents", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "article_id", null: false
    t.text "content"
    t.text "title"
    t.index ["article_id"], name: "index_search_namespaced_test_documents_on_article_id", unique: true
    t.index ["content"], name: "index_search_namespaced_test_documents_on_content", type: :fulltext
    t.index ["title", "content"], name: "index_search_namespaced_test_documents_on_title_and_content", type: :fulltext
    t.index ["title"], name: "index_search_namespaced_test_documents_on_title", type: :fulltext
  end

  create_table "topic_documents", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "account_id"
    t.json "folder_ids"
    t.json "labels"
    t.json "seen_at"
    t.text "subject"
    t.string "topic_id", null: false
    t.index ["subject"], name: "index_topic_documents_on_subject", type: :fulltext
    t.index ["topic_id"], name: "index_topic_documents_on_topic_id", unique: true
  end

  create_table "topics", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "account_id"
    t.json "folder_ids"
    t.json "labels"
    t.json "seen_at"
    t.string "subject"
  end

  create_table "unless_guarded_article", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.text "content"
    t.datetime "created_at", null: false
    t.boolean "skip_indexing", default: false
    t.string "title"
    t.datetime "updated_at", null: false
  end

  create_table "unless_guarded_article_documents", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.text "content"
    t.text "title"
    t.string "unless_guarded_article_id", null: false
    t.index ["title", "content"], name: "index_unless_guarded_article_documents_on_title_and_content", type: :fulltext
    t.index ["unless_guarded_article_id"], name: "idx_unless_guarded_article_docs_on_id", unique: true
  end

  add_foreign_key "products", "authors"
end
