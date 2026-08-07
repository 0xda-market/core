# frozen_string_literal: true

require_relative "test_helper"
require "zero_x_da/market/adapters/postgres_database"
require "zero_x_da/market/adapters/postgres_migrator"
require "zero_x_da/market/broker_earnings/postgres_store"
require "zero_x_da/market/broker_earnings/payout_records"

class BrokerPayoutPostgresTest < Minitest::Test
  DATABASE_URL = ENV["TEST_DATABASE_URL"]
  SELLER_ID = "00000000-0000-4000-8000-000000000091"
  PAYOUT_ONE = "00000000-0000-4000-8000-000000000092"
  PAYOUT_TWO = "00000000-0000-4000-8000-000000000093"
  NOW = Time.utc(2026, 8, 7, 16, 30, 0)

  def setup
    skip "TEST_DATABASE_URL is not configured" unless DATABASE_URL

    @database = ZeroXDA::Market::Adapters::PostgresDatabase.new(url: DATABASE_URL, max_connections: 2)
    ZeroXDA::Market::Adapters::PostgresMigrator.new(
      database: @database,
      path: File.expand_path("../db/migrations", __dir__)
    ).migrate!
    connection = @database.connection
    connection[Sequel.qualify(:market, :broker_earnings)].where(seller_user_id: SELLER_ID).delete
    connection[Sequel.qualify(:market, :broker_payouts)].where(seller_user_id: SELLER_ID).delete
    connection[Sequel.qualify(:market, :broker_payout_profiles)].where(seller_user_id: SELLER_ID).delete
    connection[Sequel.qualify(:market, :users)].where(id: SELLER_ID).delete
    connection[Sequel.qualify(:market, :users)].insert(id: SELLER_ID, role: "broker", status: "active")
    @store = ZeroXDA::Market::BrokerEarnings::PostgresStore.new(database: @database)
  end

  def teardown
    @database&.disconnect
  end

  def test_profile_and_active_payout_survive_reconnection
    profile = profile_record
    @store.transaction { |store| store.save_payout_profile(profile, expected_version: nil) }
    payout = payout_record(id: PAYOUT_ONE, key: "broker/#{SELLER_ID}/one")
    @store.transaction { |store| store.insert_payout(payout) }

    @database.disconnect
    @database = ZeroXDA::Market::Adapters::PostgresDatabase.new(url: DATABASE_URL, max_connections: 2)
    @store = ZeroXDA::Market::BrokerEarnings::PostgresStore.new(database: @database)

    assert_equal "TWallet", @store.payout_profile(SELLER_ID).destination
    assert_equal PAYOUT_ONE, @store.active_payout(SELLER_ID).id
  end

  def test_database_enforces_one_in_flight_payout_per_seller
    @store.transaction { |store| store.save_payout_profile(profile_record, expected_version: nil) }
    @store.transaction { |store| store.insert_payout(payout_record(id: PAYOUT_ONE, key: "one")) }

    error = assert_raises(ZeroXDA::Market::Core::Conflict) do
      @store.transaction { |store| store.insert_payout(payout_record(id: PAYOUT_TWO, key: "two")) }
    end
    assert_equal "payout_conflict", error.code
  end

  def test_database_rejects_duplicate_reference_on_same_network
    first = payout_record(id: PAYOUT_ONE, key: "one")
    @store.transaction { |store| store.insert_payout(first) }
    paid_first = ZeroXDA::Market::BrokerEarnings::Payout.new(**first.to_h.merge(
      state: "paid",
      external_reference: "tx-1",
      paid_at: NOW,
      updated_at: NOW,
      version: 1
    ))
    @store.transaction { |store| store.replace_payout(paid_first, expected_version: 0) }

    second = payout_record(id: PAYOUT_TWO, key: "two")
    @store.transaction { |store| store.insert_payout(second) }
    paid_second = ZeroXDA::Market::BrokerEarnings::Payout.new(**second.to_h.merge(
      state: "paid",
      external_reference: "tx-1",
      paid_at: NOW,
      updated_at: NOW,
      version: 1
    ))

    error = assert_raises(ZeroXDA::Market::Core::Conflict) do
      @store.transaction { |store| store.replace_payout(paid_second, expected_version: 0) }
    end
    assert_equal "duplicate_payout_reference", error.code
  end

  private

  def profile_record
    ZeroXDA::Market::BrokerEarnings::PayoutProfile.new(
      seller_user_id: SELLER_ID,
      network: "TRON",
      destination: "TWallet",
      minimum_payout_amount: "1",
      created_at: NOW
    )
  end

  def payout_record(id:, key:)
    ZeroXDA::Market::BrokerEarnings::Payout.new(
      id: id,
      seller_user_id: SELLER_ID,
      network: "TRON",
      destination: "TWallet",
      amount: "10",
      idempotency_key: key,
      created_at: NOW
    )
  end
end
