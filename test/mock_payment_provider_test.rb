# frozen_string_literal: true

require_relative "test_helper"
require "zero_x_da/market/payments/mock_provider"

class MockPaymentProviderTest < Minitest::Test
  Order = Struct.new(:id, :status, :payment, keyword_init: true)

  class Kernel
    attr_accessor :order

    def find_order(id)
      raise ZeroXDA::Market::Core::NotFound.new("order", id) unless order&.id == id

      order
    end
  end

  class ConfirmationClient
    attr_reader :calls

    def initialize
      @calls = []
    end

    def confirm(**arguments)
      @calls << arguments
      {
        "type" => "order",
        "id" => arguments.fetch(:order_id),
        "attributes" => {
          "status" => "pending",
          "payment" => { "status" => "confirmed" },
          "inventory_status" => "committed"
        }
      }
    end
  end

  def setup
    @now = Time.utc(2026, 8, 3, 15, 0, 0)
    @kernel = Kernel.new
    @kernel.order = Order.new(
      id: "order-1",
      status: "payment_pending",
      payment: {
        "status" => "pending",
        "amount" => "25.00",
        "currency" => "USDT",
        "expires_at" => (@now + 900).iso8601(6)
      }
    )
    @confirmation = ConfirmationClient.new
    @provider = ZeroXDA::Market::Payments::MockProvider.new(
      kernel: @kernel,
      confirmation_client: @confirmation,
      clock: -> { @now },
      id_generator: -> { "payment-intent-1" }
    )
  end

  def test_creates_one_authoritative_intent_per_order
    first = @provider.create_intent(order_id: "order-1")
    second = @provider.create_intent(order_id: "order-1")

    assert_same first, second
    assert_equal "payment-intent-1", first.id
    assert_equal "25.00", first.amount
    assert_equal "USDT", first.currency
    assert_equal "pending", first.status
    assert_equal @now + 900, first.expires_at
  end

  def test_succeed_calls_the_trusted_confirmation_boundary_once
    intent = @provider.create_intent(order_id: "order-1")
    succeeded = @provider.succeed(
      intent.id,
      reference: "mock-tx-1",
      data: { network: "test" }
    )
    repeated = @provider.succeed(intent.id, reference: "ignored")

    assert_same succeeded, repeated
    assert_equal "succeeded", succeeded.status
    assert_equal "mock-tx-1", succeeded.reference
    assert_equal "committed", succeeded.confirmation.dig("attributes", "inventory_status")
    assert_equal 1, @confirmation.calls.length
    assert_equal "order-1", @confirmation.calls.first.fetch(:order_id)
    assert_equal "mock", @confirmation.calls.first.dig(:data, "provider")
    assert_equal "payment-intent-1", @confirmation.calls.first.dig(:data, "payment_intent_id")
  end

  def test_failed_intent_cannot_succeed
    intent = @provider.create_intent(order_id: "order-1")
    failed = @provider.fail(
      intent.id,
      code: "declined",
      message: "declined by test",
      details: { reason: "scenario" }
    )

    assert_equal "failed", failed.status
    assert_equal "declined", failed.failure.fetch("code")
    error = assert_raises(ZeroXDA::Market::Core::Conflict) do
      @provider.succeed(intent.id)
    end
    assert_equal "invalid_payment_transition", error.code
    assert_empty @confirmation.calls
  end

  def test_expired_core_payment_cannot_create_an_intent
    @kernel.order.payment["expires_at"] = (@now - 1).iso8601(6)

    error = assert_raises(ZeroXDA::Market::Core::Conflict) do
      @provider.create_intent(order_id: "order-1")
    end

    assert_equal "payment_expired", error.code
  end

  def test_non_pending_order_is_rejected
    @kernel.order.status = "accepted"

    error = assert_raises(ZeroXDA::Market::Core::Conflict) do
      @provider.create_intent(order_id: "order-1")
    end

    assert_equal "payment_not_pending", error.code
  end
end
