# frozen_string_literal: true

require_relative "test_helper"
require "bigdecimal"
require "zero_x_da/market/payments/rack_confirmation_client"
require "zero_x_da/market/transport/manual_api"
require "zero_x_da/market/transport/manual_payment_confirmation"

class RackPaymentConfirmationClientTest < Minitest::Test
  TaskService = Struct.new(:unused) do
    def tasks(status: nil) = []
    def fetch_task(id) = raise(ZeroXDA::Market::Core::NotFound.new("manual_task", id))
    def complete_task(id, reference:, data:) = nil
    def claim_task(id, assignee:) = nil
    def reject_task(id, message:, code:, details:) = nil
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
    attr_reader :calls

    def initialize
      @calls = []
    end

    def confirm_payment(**arguments)
      @calls << arguments
      now = Time.utc(2026, 8, 3, 15, 0, 0)
      Result.new(
        order: Order.new(
          id: arguments.fetch(:order_id),
          status: "pending",
          payment: {
            "status" => "confirmed",
            "reference" => arguments.fetch(:reference),
            "data" => arguments.fetch(:data)
          },
          progress: { "reference" => "task-1" },
          result: nil,
          failure: nil,
          created_at: now,
          updated_at: now
        ),
        reservation: Reservation.new(
          quantity: BigDecimal("1"),
          status: "committed"
        )
      )
    end
  end

  def test_calls_the_operator_payment_endpoint_with_bearer_authentication
    marketplace = Marketplace.new
    operator_api = ZeroXDA::Market::Transport::ManualAPI.new(
      provider: TaskService.new,
      token: "operator-secret",
      marketplace: marketplace
    )
    client = ZeroXDA::Market::Payments::RackConfirmationClient.new(
      app: operator_api,
      token: "operator-secret"
    )

    resource = client.confirm(
      order_id: "order-1",
      reference: "mock-tx-1",
      data: { "provider" => "mock" }
    )

    assert_equal "order-1", resource.fetch("id")
    assert_equal "confirmed", resource.dig("attributes", "payment", "status")
    assert_equal 1, marketplace.calls.length
    assert_equal "mock-tx-1", marketplace.calls.first.fetch(:reference)
  end

  def test_maps_operator_authentication_failure_to_provider_contract_error
    marketplace = Marketplace.new
    operator_api = ZeroXDA::Market::Transport::ManualAPI.new(
      provider: TaskService.new,
      token: "operator-secret",
      marketplace: marketplace
    )
    client = ZeroXDA::Market::Payments::RackConfirmationClient.new(
      app: operator_api,
      token: "wrong-secret"
    )

    error = assert_raises(ZeroXDA::Market::Core::ProviderContractError) do
      client.confirm(order_id: "order-1", reference: "mock-tx-1")
    end

    assert_equal "provider_contract_error", error.code
    assert_equal 401, error.details.fetch("status")
    assert_empty marketplace.calls
  end
end
