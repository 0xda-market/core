# frozen_string_literal: true

require_relative "test_helper"
require "zero_x_da/market/adapters/postgres_database"
require "zero_x_da/market/adapters/postgres_migrator"
require "zero_x_da/market/adapters/postgres_store"
require "zero_x_da/market/providers/manual_provider"
require "zero_x_da/market/core/kernel"
require "zero_x_da/market/settlement/postgres_store"
require "zero_x_da/market/settlement/manual_provider"

class PostgresSettlementStoreTest < Minitest::Test
  DATABASE_URL = ENV["TEST_DATABASE_URL"]

  def setup
    skip "TEST_DATABASE_URL is not configured" unless DATABASE_URL

    @now = Time.utc(2026, 8, 7, 12, 0, 0)
    @database = connect
    migrate(@database)
    @database.connection.run("TRUNCATE market.orders, market.quotes, market.intents CASCADE")
  end

  def teardown
    @database&.disconnect
  end

  def test_pending_settlement_survives_reconnection_and_settles
    fulfillment = ZeroXDA::Market::Providers::ManualProvider.new(
      key: "manual.default",
      clock: -> { @now }
    )
    ids = %w[intent-1 quote-1].each
    kernel = ZeroXDA::Market::Core::Kernel.new(
      providers: { "manual.fulfillment" => fulfillment },
      store: ZeroXDA::Market::Adapters::PostgresStore.new(database: @database),
      clock: -> { @now },
      id_generator: -> { ids.next }
    )
    intent = kernel.create_intent(capability: "manual.fulfillment", payload: { action: "purchase" })
    quote = kernel.quote_intent(intent.id)
    order = kernel.accept_quote(
      quote.id,
      initial_status: "payment_pending",
      payment: {
        "status" => "pending",
        "amount" => "12.50",
        "currency" => "USDT",
        "expires_at" => (@now + 900).iso8601(6),
        "idempotency_key" => "quotes/#{quote.id}/payment"
      }
    )

    provider = settlement_provider(@database)
    pending = provider.charge(order: order, idempotency_key: "orders/#{order.id}/settlement")
    settlement_id = pending.settlement.id

    @database.disconnect
    @database = connect
    restarted = settlement_provider(@database)
    persisted = restarted.find_by_order(order.id)

    assert_equal settlement_id, persisted.id
    assert_equal "pending", persisted.state
    assert_equal BigDecimal("12.5"), persisted.expected_usdt

    settled = restarted.confirm(order_id: order.id, reference: "receipt-1", data: { operator: "admin" })
    assert_equal "settled", settled.state
    assert_equal BigDecimal("12.5"), settled.received_usdt
    assert_equal "receipt-1", settled.external_reference
  end

  private

  def connect
    ZeroXDA::Market::Adapters::PostgresDatabase.new(url: DATABASE_URL, max_connections: 2)
  end

  def migrate(database)
    ZeroXDA::Market::Adapters::PostgresMigrator.new(
      database: database,
      path: File.expand_path("../db/migrations", __dir__)
    ).migrate!
  end

  def settlement_provider(database)
    ZeroXDA::Market::Settlement::ManualProvider.new(
      clock: -> { @now },
      store: ZeroXDA::Market::Settlement::PostgresStore.new(database: database)
    )
  end
end
