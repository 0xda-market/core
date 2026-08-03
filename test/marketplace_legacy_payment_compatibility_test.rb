# frozen_string_literal: true

require_relative "test_helper"
require "zero_x_da/market/marketplace/service"

class MarketplaceLegacyPaymentCompatibilityTest < Minitest::Test
  Order = Struct.new(:id, :status, :payment, keyword_init: true)
  Reservation = Struct.new(:order_id, :customer_user_id, :status, keyword_init: true)

  class Kernel
    attr_reader :executions

    def initialize(order)
      @order = order
      @executions = []
    end

    def find_order(_id)
      @order
    end

    def execute_order(id)
      @executions << id
      Order.new(id: id, status: "pending", payment: @order.payment)
    end
  end

  class Listings
    def initialize(reservation)
      @reservation = reservation
    end

    def reservation_for_order(_id)
      @reservation
    end
  end

  def test_committed_pre_payment_order_remains_executable
    order = Order.new(id: "legacy-order", status: "accepted", payment: nil)
    reservation = Reservation.new(
      order_id: order.id,
      customer_user_id: "client-1",
      status: "committed"
    )
    kernel = Kernel.new(order)
    service = ZeroXDA::Market::Marketplace::Service.new(
      kernel: kernel,
      catalog: nil,
      pricing: nil,
      listings: Listings.new(reservation)
    )

    result = service.execute_order(
      customer_user_id: "client-1",
      order_id: order.id
    )

    assert_equal "pending", result.order.status
    assert_equal [order.id], kernel.executions
  end

  def test_new_unconfirmed_order_cannot_use_legacy_allowance
    order = Order.new(
      id: "new-order",
      status: "payment_pending",
      payment: { "status" => "pending" }
    )
    reservation = Reservation.new(
      order_id: order.id,
      customer_user_id: "client-1",
      status: "payment_pending"
    )
    service = ZeroXDA::Market::Marketplace::Service.new(
      kernel: Kernel.new(order),
      catalog: nil,
      pricing: nil,
      listings: Listings.new(reservation)
    )

    error = assert_raises(ZeroXDA::Market::Core::Conflict) do
      service.execute_order(customer_user_id: "client-1", order_id: order.id)
    end

    assert_equal "payment_required", error.code
  end
end
