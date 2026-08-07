# frozen_string_literal: true

require_relative "test_helper"
require "zero_x_da/market/broker_earnings/memory_store"
require "zero_x_da/market/broker_earnings/service"

class BrokerPayoutsTest < Minitest::Test
  Record = Struct.new(:id, :seller_user_id, :quantity, :supply_unit_price, :supply_currency, keyword_init: true)

  def setup
    @clock = -> { Time.utc(2026, 8, 7, 12, 0, 0) }
    @store = ZeroXDA::Market::BrokerEarnings::MemoryStore.new
    localization = Object.new
    localization.define_singleton_method(:amount_usdt) { |amount:, currency:| BigDecimal(amount.to_s) * (currency == "EUR" ? 2 : 1) }
    ids = %w[earning-1 payout-1].each
    @service = ZeroXDA::Market::BrokerEarnings::Service.new(store: @store, localization: localization,
                                                            clock: @clock, id_generator: -> { ids.next })
    order = Struct.new(:id).new("order-1")
    reservation = Record.new(id: "reservation-1", quantity: BigDecimal("2"),
                             supply_unit_price: BigDecimal("5"), supply_currency: "USDT")
    listing = Record.new(id: "listing-1", seller_user_id: "broker-1")
    @service.record(order: order, reservation: reservation, listing: listing)
    @service.make_available(order_id: "order-1")
  end

  def test_broker_controls_destination_and_market_queues_full_available_balance
    profile = @service.save_payout_profile(actor_user_id: "broker-1", network: "tron",
                                           destination: "TBrokerWallet", minimum_payout_amount: "10")
    assert_equal "TRON", profile.network
    assert_equal "TBrokerWallet", profile.destination

    payout = @service.queue_payout(actor_user_id: "broker-1")
    assert_equal BigDecimal("10"), payout.amount
    assert_equal "queued", payout.state
    assert_equal "TBrokerWallet", payout.destination

    balance = @service.balance(actor_user_id: "broker-1")
    assert_equal BigDecimal("0"), balance.available
    assert_equal BigDecimal("10"), balance.payout_queued
  end

  def test_operator_confirmation_marks_payout_and_earnings_paid
    @service.save_payout_profile(actor_user_id: "broker-1", network: "TRON", destination: "TBrokerWallet")
    payout = @service.queue_payout(actor_user_id: "broker-1")
    paid = @service.confirm_payout(payout_id: payout.id, external_reference: "tx-123", provider_data: { "source" => "manual" })

    assert_equal "paid", paid.state
    assert_equal "tx-123", paid.external_reference
    assert_equal "paid", @service.list(actor_user_id: "broker-1").first.state
    assert_equal BigDecimal("10"), @service.balance(actor_user_id: "broker-1").paid
  end

  def test_threshold_prevents_tiny_payouts_without_losing_available_balance
    @service.save_payout_profile(actor_user_id: "broker-1", network: "TRON", destination: "TBrokerWallet",
                                 minimum_payout_amount: "11")
    error = assert_raises(ZeroXDA::Market::Core::Conflict) do
      @service.queue_payout(actor_user_id: "broker-1")
    end
    assert_equal "payout_threshold_not_met", error.code
    assert_equal BigDecimal("10"), @service.balance(actor_user_id: "broker-1").available
  end
end
