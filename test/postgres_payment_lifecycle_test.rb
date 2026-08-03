# frozen_string_literal: true

require_relative "test_helper"
require "zero_x_da/market/adapters/postgres_database"
require "zero_x_da/market/adapters/postgres_migrator"
require "zero_x_da/market/adapters/postgres_store"

class PostgresPaymentLifecycleTest < Minitest::Test
  include KernelFixture

  DATABASE_URL = ENV["TEST_DATABASE_URL"]

  def setup
    skip "TEST_DATABASE_URL is not configured" unless DATABASE_URL

    @clock = MutableClock.new
    @database = connect
    migrate(@database)
    @database.connection.run(<<~SQL)
      TRUNCATE market.manual_tasks,
               market.orders,
               market.quotes,
               market.intents CASCADE
    SQL
  end

  def teardown
    @database&.disconnect
  end

  def test_payment_pending_and_confirmed_state_survive_reconnection
    kernel = build_postgres_kernel(@database, SequenceIDs.new)
    intent = kernel.create_intent(
      capability: "manual.fulfillment",
      payload: { action: "purchase" }
    )
    quote = kernel.quote_intent(intent.id)
    pending = kernel.accept_quote(
      quote.id,
      initial_status: "payment_pending",
      payment: {
        status: "pending",
        amount: "25",
        currency: "USDT",
        expires_at: quote.expires_at.iso8601(6),
        idempotency_key: "quotes/#{quote.id}/payment"
      }
    )

    @database.disconnect
    @database = connect
    restarted = build_postgres_kernel(
      @database,
      -> { raise "persisted payment lifecycle must not generate an id" }
    )
    restored = restarted.find_order(pending.id)

    assert_equal "payment_pending", restored.status
    assert_equal "pending", restored.payment.fetch("status")
    assert_equal "25", restored.payment.fetch("amount")
    assert_equal "USDT", restored.payment.fetch("currency")

    confirmed = restarted.confirm_order_payment(
      restored.id,
      reference: "payment-1",
      data: { provider: "test", transaction_id: "tx-1" }
    )
    assert_equal "accepted", confirmed.status
    assert_equal "confirmed", confirmed.payment.fetch("status")

    @database.disconnect
    @database = connect
    final_kernel = build_postgres_kernel(
      @database,
      -> { raise "persisted confirmation must not generate an id" }
    )
    final = final_kernel.find_order(pending.id)

    assert_equal "accepted", final.status
    assert_equal "payment-1", final.payment.fetch("reference")
    assert_equal "tx-1", final.payment.dig("data", "transaction_id")
  end

  private

  def connect
    ZeroXDA::Market::Adapters::PostgresDatabase.new(
      url: DATABASE_URL,
      max_connections: 2
    )
  end

  def migrate(database)
    ZeroXDA::Market::Adapters::PostgresMigrator.new(
      database: database,
      path: File.expand_path("../db/migrations", __dir__)
    ).migrate!
  end

  def build_postgres_kernel(database, id_generator)
    provider = TestProvider.new(clock: @clock, quote_ttl: 60)
    ZeroXDA::Market::Core::Kernel.new(
      providers: { "manual.fulfillment" => provider },
      store: ZeroXDA::Market::Adapters::PostgresStore.new(database: database),
      clock: @clock,
      id_generator: id_generator
    )
  end
end
