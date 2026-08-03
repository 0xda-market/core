# frozen_string_literal: true

require_relative "test_helper"
require "bigdecimal"
require "json"
require "rack/mock"
require "zero_x_da/market/transport/manual_api"
require "zero_x_da/market/transport/manual_payment_confirmation"

class ManualPaymentConfirmationTest < Minitest::Test
  TaskService = Struct.new(:unused) do
    def tasks(status: nil)
      []
    end

    def fetch_task(_id)
      raise ZeroXDA::Market::Core::NotFound.new("manual_task", "missing")
    end

    def complete_task(_id, reference:, data:)
      nil
    end

    def claim_task(_id, assignee:)
      nil
    end

    def reject_task(_id, message:, code:, details:)
      nil
    end
  end

  Order = Struct.new(
    :id,
    :status,
    :payment,
    :progress,
    :result,
    :failure,
    :created_at,
    :updated_at,
    keyword_init: true
  )
  Reservation = Struct.new(:quantity, :status, keyword_init: true)
  Result = Struct.new(:order, :reservation, keyword_init: true)

  class Marketplace
    attr_reader :arguments

    def confirm_payment(**arguments)
      @arguments = arguments
      now = Time.utc(2026, 8, 3, 12, 0, 0)
      Result.new(
        order: Order.new(
          id: arguments.fetch(:order_id),
          status: "pending",
          payment: {
            "status" => "confirmed",
            "reference" => arguments.fetch(:reference),
            "data" => arguments.fetch(:data)
          },
          progress: { "reference" => "task-1", "data" => {} },
          result: nil,
          failure: nil,
          created_at: now,
          updated_at: now
        ),
        reservation: Reservation.new(
          quantity: BigDecimal("2"),
          status: "committed"
        )
      )
    end
  end

  def setup
    @marketplace = Marketplace.new
    api = ZeroXDA::Market::Transport::ManualAPI.new(
      provider: TaskService.new,
      token: "operator-secret",
      marketplace: @marketplace
    )
    @client = Rack::MockRequest.new(api)
  end

  def test_requires_operator_authentication
    response = @client.post(
      "/v1/market/orders/order-1/payment/confirm",
      "CONTENT_TYPE" => "application/json",
      input: JSON.generate(reference: "payment-1")
    )

    assert_equal 401, response.status
  end

  def test_confirms_payment_and_returns_fulfillment_state
    response = @client.post(
      "/v1/market/orders/order-1/payment/confirm",
      "HTTP_AUTHORIZATION" => "Bearer operator-secret",
      "CONTENT_TYPE" => "application/json",
      input: JSON.generate(
        reference: "payment-1",
        data: { provider: "manual", transaction_id: "tx-1" }
      )
    )

    assert_equal 200, response.status, response.body
    assert_equal(
      {
        order_id: "order-1",
        reference: "payment-1",
        data: { "provider" => "manual", "transaction_id" => "tx-1" }
      },
      @marketplace.arguments
    )
    attributes = JSON.parse(response.body).dig("data", "attributes")
    assert_equal "pending", attributes.fetch("status")
    assert_equal "confirmed", attributes.dig("payment", "status")
    assert_equal "committed", attributes.fetch("inventory_status")
    assert_equal "2.0", attributes.fetch("quantity")
    assert_equal "task-1", attributes.dig("progress", "reference")
  end
end
