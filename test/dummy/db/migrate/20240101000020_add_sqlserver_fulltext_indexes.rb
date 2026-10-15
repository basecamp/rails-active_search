class AddSqlserverFulltextIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEXES = {
    article_documents: %i[ title content ],
    record_documents: %i[ title body ],
    comment_documents: %i[ body ],
    admin_documents: %i[ title body ],
    guarded_article_documents: %i[ title content ],
    unless_guarded_article_documents: %i[ title content ],
    proc_guarded_article_documents: %i[ title content ],
    search_namespaced_test_documents: %i[ title content ],
    topic_documents: %i[ subject ]
  }.freeze

  def up
    return unless connection.adapter_name.downcase == "sqlserver"

    execute "IF FULLTEXTSERVICEPROPERTY('IsFullTextInstalled') <> 1 THROW 50000, 'SQL Server Full-Text Search is not installed', 1"
    execute "IF NOT EXISTS (SELECT 1 FROM sys.fulltext_catalogs WHERE name = 'active_search') CREATE FULLTEXT CATALOG [active_search]"

    INDEXES.each do |table, columns|
      key_index = "index_#{table}_on_id_for_fulltext"
      add_index table, :id, unique: true, name: key_index
      fields = columns.map { |column| "[#{column}] LANGUAGE 1033" }.join(", ")
      execute "CREATE FULLTEXT INDEX ON [#{table}] (#{fields}) KEY INDEX [#{key_index}] ON [active_search] WITH CHANGE_TRACKING AUTO"
    end
  end

  def down
    return unless connection.adapter_name.downcase == "sqlserver"

    INDEXES.each_key do |table|
      execute "DROP FULLTEXT INDEX ON [#{table}]"
      remove_index table, name: "index_#{table}_on_id_for_fulltext"
    end
  end
end
