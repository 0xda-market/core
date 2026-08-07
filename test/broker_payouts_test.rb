# frozen_string_literal: true

require_relative "test_helper"
require "zero_x_da/market/broker_earnings/memory_store"
require "zero_x_da/market/broker_earnings/service"

class BrokerPayoutsTest < Minitest::Test
  Record = Struct.new(:id, :seller_user_id, :quantity, :supply_unit_price, :supply_currency, keyword_init: true)

  def setup
    @clock = -> { Time.utc(2026, 8, 7, 16, 30, 0) }
    @store = ZeroXDA::Market::BrokerEarnings::MemoryStore.new
    localization = Object.new
    localization.define_singleton_method(:amount_usdt) do |amount:, currency:|
      BigDecimal(amount.to_s) * (currency == "EUR" ? 2 : 1)
    end
    ids = (1..40).map { |index| "id-#{index}" }.each
    @service = ZeroXDA::Market::BrokerEarnings::Service.new(
      store: @store,
      localization: localization,
      clock: @clock,
      id_generator: -> { ids.next }
    )
  end

  def test_profile_update_requires_exact_version
    profile = @service.save_payout_profile(
      actor_user_id: "broker-1",
      network: "tron",
      destination: "TWallet",
      minimum_payout_amount: "10"
    )
    assert_equal "TRON", profile.network
    assert_equal 0, profile.version

    assert_raises(ArgumentError) do
      @service.save_payout_profile(actor_user_id: "broker-1", network: "TRON", destination: "TNew")
    end

    error = assert_raises(ZeroXDA::Market::Core::ConcurrencyConflict) do
      @service.save_payout_profile(
        actor_user_id: "broker-1",
        network: "TRON",
        destination: "TNew",
        expected_version: 9
      )
    end
    assert_equal "concurrency_conflict", error.code

    updated = @service.save_payout_profile(
      actor_user_id: "broker-1",
      network: "TRON",
      destination: "TNew",
      expected_version: 0
    )
    assert_equal 1, updated.version
    assert_equal "TNew", updated.destination
  end

  def test_queue_batches_available_balance_and_is_idempotent_while_in_flight
    create_available_earning(order_id: "order-1", seller: "broker-1", unit_price: "5", quantity: "2")
    @service.save_payout_profile(actor_user_id: "broker-1", network: "TRON", destination: "TWallet")

    payout = @service.queue_payout(actor_user_id: "broker-1")
    assert_equal BigDecimal("10"), payout.amount
    assert_equal "queued", payout.state
    assert_match(%r{\Abroker/broker-1/[0-9a-f]{64}\z}, payout.idempotency_key)

    create_available_earning(order_id: "order-2", seller: "broker-1", unit_price: "3", quantity: "1")
    retry_result = @service.queue_payout(actor_user_id: "broker-1")

    assert_equal payout.id, retry_result.id
    balance = @service.balance(actor_user_id: "broker-1")
    assert_equal BigDecimal("3"), balance.available
    assert_equal BigDecimal("10"), balance.payout_queued
  end

  def test_threshold_rejects_without_claiming_earnings
    create_available_earning(order_id: "order-1", seller: "broker-1", unit_price: "10", quantity: "1")
    @service.save_payout_profile(
      actor_user_id: "broker-1",
      network: "TRON",
      destination: "TWallet",
      minimum_payout_amount: "11"
    )

    error = assert_raises(ZeroXDA::Market::Core::Conflict) do
      @service.queue_payout(actor_user_id: "broker-1")
    end
    assert_equal "payout_threshold_not_met", error.code
    assert_equal BigDecimal("10"), @service.balance(actor_user_id: "broker-1").available
    assert_empty @service.list_payouts(actor_user_id: "broker-1")
  end

  def test_confirmation_atomically_marks_payout_and_exact_earnings_paid
    create_available_earning(order_id: "order-1", seller: "broker-1", unit_price: "4", quantity: "2")
    create_available_earning(order_id: "order-2", seller: "broker-1", unit_price: "2", quantity: "1")
    @service.save_payout_profile(actor_user_id: "broker-1", network: "TRON", destination: "TWallet")
    payout = @service.queue_payout(actor_user_id: "broker-1")

    paid = @service.confirm_payout(
      payout_id: payout.id,
      external_reference: "tx-123",
      provider_data: { "executor" => "manual-v1" }
    )

    assert_equal "paid", paid.state
    assert_equal "tx-123", paid.external_reference
    assert_equal BigDecimal("10"), @service.balance(actor_user_id: "broker-1").paid
    assert @service.list(actor_user_id: "broker-1").all? { |earning| earning.state == "paid" }

    retry_result = @service.confirm_payout(payout_id: payout.id, external_reference: "tx-123")
    assert_equal paid.id, retry_result.id

    error = assert_raises(ZeroXDA::Market::Core::Conflict) do
      @service.confirm_payout(payout_id: payout.id, external_reference: "different-tx")
    end
    assert_equal "payout_already_paid", error.code
  end

  def test_same_external_reference_cannot_pay_two_payouts_on_same_network
    first = queue_for(seller: "broker-1", order_id: "order-1", destination: "TOne")
    second = queue_for(seller: "broker-2", order_id: "order-2", destination: "TTwo")

    @service.confirm_payout(payout_id: first.id, external_reference: "shared-tx")
    error = assert_raises(ZeroXDA::Market::Core::Conflict) do
      @service.confirm_payout(payout_id: second.id, external_reference: "shared-tx")
    end
    assert_equal "duplicate_payout_reference", error.code
  end

  def test_same_reference_may_exist_on_a_different_network
    first = queue_for(seller: "broker-1", order_id: "order-1", destination: "TOne", network: "TRON")
    second = queue_for(seller: "broker-2", order_id: "order-2", destination: "0xTwo", network: "ETHEREUM")

    @service.confirm_payout(payout_id: first.id, external_reference: "shared-reference")
    paid = @service.confirm_payout(payout_id: second.id, external_reference: "shared-reference")
    assert_equal "paid", paid.state
  end

  private

  def queue_for(seller:, order_id:, destination:, network: "TRON")
    create_available_earning(order_id: order_id, seller: seller, unit_price: "5", quantity: "1")
    @service.save_payout_profile(actor_user_id: seller, network: network, destination: destination)
    @service.queue_payout(actor_user_id: seller)
  end

  def create_available_earning(order_id:, seller:, unit_price:, quantity:)
    reservation = Record.new(
      id: "reservation-#{order_id}",
      quantity: BigDecimal(quantity),
      supply_unit_price: BigDecimal(unit_price),
      supply_currency: "USDT"
    )
    listing = Record.new(id: "listing-#{order_id}", seller_user_id: seller)
    @service.record(order: Struct.new(:id).new(order_id), reservation: reservation, listing: listing)
    @service.make_available(order_id: order_id)
  end
end
