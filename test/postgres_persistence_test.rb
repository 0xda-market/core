# frozen_string_literal: true

require_relative "test_helper"
require "sequel"
require "zero_x_da/market/adapters/postgres_database"
require "zero_x_da/market/adapters/postgres_manual_task_store"
require "zero_x_da/market/adapters/postgres_store"
require "zero_x_da/market/catalog/postgres_store"
require "zero_x_da/market/core/kernel"
require "zero_x_da/market/providers/manual_provider"

class PostgresPersistenceTest < Minitest::Test
  include KernelFixture

  def setup
    skip "TEST_DATABASE_URL is not configured" unless ENV["TEST_DATABASE_URL"]

    @database = connect
    reset_database(@database)
    migrate(@database)
  end

  def teardown
    @database&.disconnect
  end

  def test_persists_order_and_manual_task_across_reconnection
    clock = MutableClock.new
    ids = SequenceIDs.new
    kernel, provider = build_application(@database, clock, ids)
    intent = kernel.create_intent(
      capability: provider.key,
      payload: { "delivery" => "premium_3m" }
    )
    quote = kernel.quote_intent(intent.id)
    order = kernel.accept_quote(quote.id)

    pending = kernel.execute_order(order.id)
    assert_equal "pending", pending.status
    task_id = pending.progress.fetch("reference")

    @database.disconnect
    @database = connect
    restarted_kernel, restarted_provider = build_application(
      @database,
      clock,
      -> { raise "a persisted lifecycle must not generate another id" }
    )

    assert_equal "pending", restarted_kernel.find_order(order.id).status
    assert_equal order.id, restarted_provider.fetch_task(task_id).order_id

    restarted_provider.complete_task(
      task_id,
      reference: "operator-result-1",
      data: { delivered: true }
    )
    completed = restarted_kernel.execute_order(order.id)

    assert_equal "succeeded", completed.status
    assert_equal "operator-result-1", completed.result.fetch("reference")
    assert completed.result.dig("data", "delivered")
    assert_equal 1, restarted_provider.fetch_task(task_id).version
    assert_equal provider.key, restarted_provider.key
  end

  def test_migrations_are_idempotent
    migrate(@database)

    versions = @database.connection[
      Sequel.qualify(:market, :schema_migrations)
    ].select_map(:version)
    assert_equal(
      %w[
        001_initial 002_telegram_demo 003_users_and_identities
        004_products 005_pricing 006_replace_premium_9m_with_12m
        007_product_catalog_localizations 008_legacy_catalog_rollback_window
        009_currencies_as_products 010_broker_listings
        011_marketplace_inventory
      ],
      versions
    )
  end

  def test_product_catalog_is_seeded_and_survives_reconnection
    store = ZeroXDA::Market::Catalog::PostgresStore.new(database: @database)

    assert_equal 9, store.list_products(status: "active").length
    premium = store.find_product("premium_12m")
    assert_equal "Telegram Premium 12 months", premium.name
    assert_equal "Premium 12m", premium.short_name
    assert_equal 3, premium.position
    assert_equal 12, premium.metadata.fetch("duration_months")

    @database.disconnect
    @database = connect
    reloaded = ZeroXDA::Market::Catalog::PostgresStore.new(database: @database)

    assert_equal "Telegram Premium 12 months", reloaded.find_product("premium_12m").name
  end

  private

  def connect
    ZeroXDA::Market::Adapters::PostgresDatabase.new(
      url: ENV.fetch("TEST_DATABASE_URL"),
      max_connections: 3
    )
  end

  def reset_database(database)
    database.connection.run("DROP SCHEMA IF EXISTS market CASCADE")
  end

  def migrate(database)
    database.migrate!
  end

  def build_application(database, clock, ids)
    provider = ZeroXDA::Market::Providers::ManualProvider.new(
      key: "manual.test",
      task_store: ZeroXDA::Market::Adapters::PostgresManualTaskStore.new(database: database),
      clock: clock,
      id_generator: ids
    )
    kernel = ZeroXDA::Market::Core::Kernel.new(
      providers: { provider.key => provider },
      store: ZeroXDA::Market::Adapters::PostgresStore.new(database: database),
      clock: clock,
      id_generator: ids
    )
    [kernel, provider]
  end
end
