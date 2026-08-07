# frozen_string_literal: true

require_relative "test_helper"
require "bigdecimal"
require "zero_x_da/market/core/records"
require "zero_x_da/market/settlement/manual_provider"

class ManualSettlementProviderTest < Minitest::Test
  Order = Struct.new(:id, :payment, keyword_init: true)
  Quote = Struct.new(:id, keyword_init: true)

  def setup
    @now = Time.utc(2026, 8, 7, 12, 0, 0)
    @provider = ZeroXDA::Market::Settlement::ManualProvider.new(
      clock: -> { @now },
      variable_fee_bps: 125,
      fixed_cost_usdt: "0.15",
      tolerance_bps: 50
    )
    @order = Order.new(
      id: "order-1",
      payment: {
        "amount" => "10.0",
        "currency" => "USDT",
        "expires_at" => (@now + 900).iso8601(6)
      }
    )
  end

  def test_declares_quote_time_cost
    cost = @provider.cost(quote: Quote.new(id: "quote-1"))

    assert_equal 125, cost.variable_fee_bps
    assert_equal BigDecimal("0.15"), cost.fixed_cost_usdt
  end

  def test_charge_is_idempotent_and_pending
    first = @provider.charge(order: @order, idempotency_key: "orders/order-1/settlement")
    second = @provider.charge(order: @order, idempotency_key: "orders/order-1/settlement")

    assert_instance_of ZeroXDA::Market::Core::Contracts::PendingSettlement, first
    assert_equal first.settlement.id, second.settlement.id
    assert_equal "pending", first.settlement.state
  end

  def test_confirm_settles_within_tolerance
    pending = @provider.charge(order: @order, idempotency_key: "orders/order-1/settlement")
    settlement = @provider.confirm(
      order_id: @order.id,
      reference: "manual-receipt-1",
      received_usdt: "9.96",
      data: { operator: "admin" }
    )
    verified = @provider.verify(settlement: settlement)

    assert_equal pending.settlement.id, settlement.id
    assert_equal "settled", settlement.state
    assert_equal BigDecimal("9.96"), settlement.received_usdt
    assert_instance_of ZeroXDA::Market::Core::Contracts::SettlementResult, verified
  end

  def test_confirm_fails_closed_outside_tolerance
    @provider.charge(order: @order, idempotency_key: "orders/order-1/settlement")

    error = assert_raises(ZeroXDA::Market::Core::Conflict) do
      @provider.confirm(
        order_id: @order.id,
        reference: "manual-receipt-2",
        received_usdt: "9.90"
      )
    end

    assert_equal "settlement_amount_mismatch", error.code
  end
end
