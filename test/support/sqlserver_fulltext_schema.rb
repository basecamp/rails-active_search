# test/support/sqlserver_fulltext_schema.rb
# frozen_string_literal: true

# Restores SQL Server full-text objects that Active Record's Ruby schema dumper cannot represent.
module SqlserverFulltextSchema
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

  class << self
    def rebuild!(connection = ActiveRecord::Base.connection)
      connection.execute(
        "IF FULLTEXTSERVICEPROPERTY('IsFullTextInstalled') <> 1 " \
          "THROW 50000, 'SQL Server Full-Text Search is not installed', 1"
      )
      connection.execute(
        "IF NOT EXISTS (SELECT 1 FROM sys.fulltext_catalogs WHERE name = 'active_search') " \
          "CREATE FULLTEXT CATALOG [active_search]"
      )

      INDEXES.each do |table, columns|
        rebuild_index(connection, table, columns) if connection.table_exists?(table)
      end
    end

    private
      def rebuild_index(connection, table, columns)
        if connection.select_value(
          "SELECT OBJECTPROPERTY(OBJECT_ID('#{table}'), 'TableHasActiveFulltextIndex')"
        ) == 1
          connection.execute("DROP FULLTEXT INDEX ON [#{table}]")
        end

        fields = columns.map { |column| "[#{column}] LANGUAGE 1033" }.join(", ")
        key_index = "index_#{table}_on_id_for_fulltext"
        connection.execute(
          "CREATE FULLTEXT INDEX ON [#{table}] (#{fields}) KEY INDEX [#{key_index}] " \
            "ON [active_search] WITH CHANGE_TRACKING AUTO"
        )
      end
  end
end
