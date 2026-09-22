require "test_helper"

class VerifiedVersionsTest < ActiveSupport::TestCase
  COMPOSE = Rails.root.join("../../docker-compose.yml")
  README = Rails.root.join("../../README.md")

  test "the README's version table names the version each store runs" do
    rows = documented_rows
    assert rows.any?, "the README must carry a Verified versions section with a store table"

    image_versions(COMPOSE.read).each do |image, version|
      row = row_for(rows, image)

      assert row, "docker-compose.yml runs #{image}, which the README's version table has no row for"
      assert_includes row, version,
        "#{image} runs #{version} in docker-compose.yml, and its README row says #{row.inspect}"
    end
  end

  private
    def documented_rows
      section = README.read[/## Verified versions.*?\n## /m].to_s

      section.scan(/^\|\s*([^|]+?)\s*\|(.+)\|$/).each_with_object({}) do |(store, versions), rows|
        next if store == "Store" || store.match?(/\A-+\z/)
        rows[normalize(store)] = versions
      end
    end

    def image_versions(compose)
      compose.scan(/^\s+image:\s+(\S+)$/).flatten.map do |ref|
        name_and_tag = ref.split("@").first
        [ name_and_tag.split(":").first.split("/").last, name_and_tag.split(":").last ]
      end.uniq
    end

    def row_for(rows, image)
      key = normalize(image)
      matches = rows.select { |store, _| store.start_with?(key) || key.start_with?(store) }

      assert_equal 1, matches.size, "#{image} matches #{matches.keys.inspect} in the README table" if matches.size > 1
      matches.values.first
    end

    def normalize(name)
      name.downcase.gsub(/[^a-z0-9]/, "")
    end
end
