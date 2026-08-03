# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "rack/mock"
require "zero_x_da/market/payments/mock_provider"
require "zero_x_da/market/transport/mock_payment_api"

class MockPaymentAPITest < Minitest::Test
  Order = Struct.new(:id, :status, :payment, keyword_init: true)

  class Kernel
    def initialize(order)
      @order = order
    end

    def find_order(id)
      raise ZeroXDA::Market::Core::NotFound.new("order", id) unless @order.id == id

      @order
    end
  end

  class ConfirmationClient
    def confirm(order_id:, reference:, data:)
      {
        "type" => "order",
        "id" => order_id,
        "attributes" => {
          "status" => "pending",
          "payment" => {
            "status" => "confirmed",
            "reference" => reference,
            "data" => data
          },
          "inventory_status" => "committed"
        }
      }
    end
  end

  def setup
    now = Time.utc(2026, 8, 3, 15, 0, 0)
    order = Order.new(
      id: "order-1",
      status: "payment_pending",
      payment: {
        "status" => "pending",
        "amount" => "25.00",
        "currency" => "USDT",
        "expires_at" => (now + 900).iso8601(6)
      }
    )
    provider = ZeroXDA::Market::Payments::MockProvider.new(
      kernel: Kernel.new(order),
      confirmation_client: ConfirmationClient.new,
      clock: -> { now },
      id_generator: -> { "payment-intent-1" }
    )
    api = ZeroXDA::Market::Transport::MockPaymentAPI.new(
      provider: provider,
      token: "mock-secret"
    )
    @client = Rack::MockRequest.new(api)
  end

  def test_requires_mock_provider_authentication
    response = @client.post(
      "/v1/payment-intents",
      "CONTENT_TYPE" => "application/json",
      input: JSON.generate(order_id: "order-1")
    )

    assert_equal 401, response.status
  end

  def test_creates_reads_and_succeeds_a_payment_intent
    created = post("/v1/payment-intents", order_id: "order-1")

    assert_equal 201, created.status, created.body
    created_data = JSON.parse(created.body).fetch("data")
    assert_equal "payment-intent-1", created_data.fetch("id")
    assert_equal "25.00", created_data.dig("attributes", "amount")
    assert_equal "pending", created_data.dig("attributes", "status")

    fetched = @client.get(
      "/v1/payment-intents/payment-intent-1",
      "HTTP_AUTHORIZATION" => "Bearer mock-secret"
    )
    assert_equal 200, fetched.status

    succeeded = post(
      "/v1/payment-intents/payment-intent-1/succeed",
      reference: "mock-tx-1",
      data: { scenario: "success" }
    )
    attributes = JSON.parse(succeeded.body).dig("data", "attributes")

    assert_equal 200, succeeded.status, succeeded.body
    assert_equal "succeeded", attributes.fetch("status")
    assert_equal "mock-tx-1", attributes.fetch("reference")
    assert_equal "committed", attributes.dig("confirmation", "attributes", "inventory_status")
  end

  def test_fail_and_expire_are_explicit_terminal_scenarios
    post("/v1/payment-intents", order_id: "order-1")
    failed = post(
      "/v1/payment-intents/payment-intent-1/fail",
      code: "declined",
      message: "declined by test"
    )

    assert_equal 200, failed.status
    assert_equal "failed", JSON.parse(failed.body).dig("data", "attributes", "status")

    conflict = post("/v1/payment-intents/payment-intent-1/expire")
    assert_equal 409, conflict.status
    assert_equal(
      "invalid_payment_transition",
      JSON.parse(conflict.body).dig("errors", 0, "code")
    )
  end

  private

  def post(path, document = {})
    @client.post(
      path,
      "HTTP_AUTHORIZATION" => "Bearer mock-secret",
      "CONTENT_TYPE" => "application/json",
      input: JSON.generate(document)
    )
  end
end
