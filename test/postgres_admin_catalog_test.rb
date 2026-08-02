# frozen_string_literal: true

require_relative "test_helper"
require "zero_x_da/market/adapters/postgres_database"
require "zero_x_da/market/adapters/postgres_migrator"
require "zero_x_da/market/catalog/postgres_store"
require "zero_x_da/market/catalog/service"

class PostgresAdminCatalogTest < Minitest::Test
  DATABASE_URL = ENV["TEST_DATABASE_URL"]

  def setup
    skip "TEST_DATABASE_URL is not configured" unless DATABASE_URL

    @database = ZeroXDA::Market::Adapters::PostgresDatabase.new(url: DATABASE_URL)
    ZeroXDA::Market::Adapters::PostgresMigrator.new(
      database: @database,
      path: File.expand_path("../db/migrations", __dir__)
    ).migrate!
  end

  def teardown
    @database&.disconnect
  end

  def test_persists_admin_product_and_localization_updates_with_concurrency
    connection = @database.connection
    connection.transaction(rollback: :always) do
      actor_user_id = "00000000-0000-4000-8000-000000000099"
      connection[Sequel.qualify(:market, :users)].insert(
        id: actor_user_id,
        role: "admin",
        status: "active"
      )
      clock = MutableClock.new(Time.utc(2026, 8, 2, 12, 0, 0))
      store = ZeroXDA::Market::Catalog::PostgresStore.new(database: @database)
      catalog = ZeroXDA::Market::Catalog::Service.new(store: store, clock: clock)
      product = catalog.find_product("premium_3m")

      updated = catalog.update_product(
        sku: product.sku,
        actor_user_id: actor_user_id,
        expected_version: product.version,
        attributes: {
          "short_name" => "Premium · 3m",
          "position" => product.position + 10,
          "metadata" => product.metadata
        }
      )
      assert_equal product.version + 1, updated.version
      assert_equal actor_user_id, updated.updated_by_user_id
      assert_equal "Premium · 3m", store.find_product(product.sku).short_name

      assert_raises(ZeroXDA::Market::Core::ConcurrencyConflict) do
        catalog.update_product(
          sku: product.sku,
          actor_user_id: actor_user_id,
          expected_version: product.version,
          attributes: { "position" => product.position }
        )
      end

      localization = store.find_localization(product.sku, "uk_UA")
      revised = catalog.save_localization(
        sku: product.sku,
        locale: "uk_UA",
        full_name: "Telegram Premium на 3 місяці",
        button_label: "Premium · 3 міс.",
        actor_user_id: actor_user_id,
        expected_version: localization.version
      )
      assert_equal localization.version + 1, revised.version
      assert_equal "Telegram Premium на 3 місяці", store.find_product(product.sku, locale: "uk_UA").name
    end
  end
end
