# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "rack/mock"
require "zero_x_da/market/broker_earnings/memory_store"
require "zero_x_da/market/broker_earnings/service"
require "zero_x_da/market/transport/json_api"
require "zero_x_da/market/transport/manual_api"
require "zero_x_da/market/transport/manual_payment_confirmation"

class BrokerPayoutTransportTest < Minitest::Test
  Record = Struct.new(:id, :seller_user_id, :quantity, :supply_unit_price, :supply_currency, keyword_init: true)

  class ManualProvider
    def tasks(status: nil) = []
    def fetch_task(*) = nil
    def complete_task(*) = nil
    def claim_task(*) = nil
    def reject_task(*) = nil
  end

  def setup
    store = ZeroXDA::Market::BrokerEarnings::MemoryStore.new
    localization = Object.new
    localization.define_singleton_method(:amount_usdt) { |amount:, currency:| BigDecimal(amount.to_s) }
    ids = %w[earning-1 payout-1 payout-2].each
    @earnings = ZeroXDA::Market::BrokerEarnings::Service.new(
      store: store,
      localization: localization,
      clock: -> { Time.utc(2026, 8, 7, 16, 30, 0) },
      id_generator: -> { ids.next }
    )
    reservation = Record.new(id: "reservation-1", quantity: BigDecimal("2"),
                             supply_unit_price: BigDecimal("5"), supply_currency: "USDT")
    listing = Record.new(id: "listing-1", seller_user_id: "broker-1")
    @earnings.record(order: Struct.new(:id).new("order-1"), reservation: reservation, listing: listing)
    @earnings.make_available(order_id: "order-1")
  end

  def test_public_api_exposes_profile_balance_and_queue_without_hidden_dependency_lookup
    api = ZeroXDA::Market::Transport::JSONAPI.new(kernel: Object.new, broker_earnings: @earnings)
    client = Rack::MockRequest.new(api)

    profile_response = client.put(
      "/v1/broker/payout-profile",
      "CONTENT_TYPE" => "application/json",
      input: JSON.generate(actor_user_id: "broker-1", network: "TRON", destination: "TWallet")
    )
    assert_equal 200, profile_response.status

    queue_response = client.post(
      "/v1/broker/payouts/queue",
      "CONTENT_TYPE" => "application/json",
      input: JSON.generate(actor_user_id: "broker-1")
    )
    assert_equal 201, queue_response.status
    document = JSON.parse(queue_response.body)
    assert_equal "queued", document.dig("data", "attributes", "status")
    assert_equal "10.0", document.dig("data", "attributes", "amount")

    balance_response = client.get("/v1/broker/balance?actor_user_id=broker-1")
    assert_equal 200, balance_response.status
    balance = JSON.parse(balance_response.body).dig("data", "attributes")
    assert_equal "0.0", balance.fetch("available")
    assert_equal "10.0", balance.fetch("payout_queued")
  end

  def test_operator_confirmation_uses_explicit_earnings_dependency
    @earnings.save_payout_profile(actor_user_id: "broker-1", network: "TRON", destination: "TWallet")
    payout = @earnings.queue_payout(actor_user_id: "broker-1")
    api = ZeroXDA::Market::Transport::ManualAPI.new(
      provider: ManualProvider.new,
      token: "operator-token",
      broker_earnings: @earnings
    )
    client = Rack::MockRequest.new(api)

    response = client.post(
      "/v1/broker/payouts/#{payout.id}/confirm",
      "HTTP_AUTHORIZATION" => "Bearer operator-token",
      "CONTENT_TYPE" => "application/json",
      input: JSON.generate(reference: "tx-123", data: { executor: "manual-v1" })
    )

    assert_equal 200, response.status
    document = JSON.parse(response.body)
    assert_equal "paid", document.dig("data", "attributes", "status")
    assert_equal "tx-123", document.dig("data", "attributes", "external_reference")
  end
end
