# frozen_string_literal: true

require_relative "test_helper"
require "bigdecimal"
require "zero_x_da/market/broker_orders/decision"
require "zero_x_da/market/broker_orders/memory_store"
require "zero_x_da/market/broker_orders/service"

class BrokerOrderDecisionsTest < Minitest::Test
  User = Struct.new(:id, keyword_init: true)
  Listing = Struct.new(:id, :seller_user_id, :sku, keyword_init: true)
  Reservation = Struct.new(:id, :listing_id, :customer_user_id, :order_id, :quantity, keyword_init: true)
  Order = Struct.new(:id, :status, :payment, :progress, :payload, keyword_init: true)
  Context = Struct.new(:reservation, :listing, keyword_init: true)

  class Listings
    def initialize(reservation:, listing:, broker_ids:)
      @reservation = reservation
      @listing = listing
      @broker_ids = broker_ids
    end

    def broker_user(actor_user_id:)
      raise ZeroXDA::Market::Core::Forbidden.new("broker role is required") unless @broker_ids.include?(actor_user_id)

      User.new(id: actor_user_id)
    end

    def broker_order_context_for_reservation(reservation)
      Context.new(reservation: reservation, listing: @listing)
    end

    def broker_order_context(actor_user_id:, order_id:)
      broker_user(actor_user_id: actor_user_id)
      unless actor_user_id == @listing.seller_user_id && order_id == @reservation.order_id
        raise ZeroXDA::Market::Core::Forbidden.new("marketplace order belongs to another broker")
      end

      Context.new(reservation: @reservation, listing: @listing)
    end
  end

  class Kernel
    attr_accessor :order

    def find_order(id)
      raise ZeroXDA::Market::Core::NotFound.new("order", id) unless order.id == id

      order
    end

    def execute_order(id)
      find_order(id)
      if order.progress.nil?
        self.order = order.dup
        order.progress = { "reference" => "task-1" }
        order.status = "pending"
      else
        self.order = order.dup
        order.status = "succeeded"
      end
      order
    end
  end

  class Provider
    attr_reader :claims, :completions

    def initialize
      @claims = []
      @completions = []
    end

    def claim_task(id, assignee:)
      @claims << [id, assignee]
    end

    def complete_task(id, reference:, data:)
      @completions << [id, reference, data]
    end
  end

  def setup
    @reservation = Reservation.new(
      id: "reservation-1",
      listing_id: "listing-1",
      customer_user_id: "client-1",
      order_id: "order-1",
      quantity: BigDecimal("2")
    )
    @listing = Listing.new(id: "listing-1", seller_user_id: "broker-1", sku: "premium_3m")
    @kernel = Kernel.new
    @kernel.order = Order.new(
      id: "order-1",
      status: "payment_pending",
      payment: { "status" => "pending" },
      progress: nil,
      payload: { "product" => { "name" => "Premium 3m", "total_price_usdt" => "25" } }
    )
    @provider = Provider.new
    @service = ZeroXDA::Market::BrokerOrders::Service.new(
      store: ZeroXDA::Market::BrokerOrders::MemoryStore.new,
      kernel: @kernel,
      listings: Listings.new(
        reservation: @reservation,
        listing: @listing,
        broker_ids: %w[broker-1 broker-2]
      ),
      provider: @provider,
      clock: -> { Time.utc(2026, 8, 4, 12, 0, 0) }
    )
    @service.request(order: @kernel.order, reservation: @reservation)
  end

  def test_only_the_allocated_listing_owner_can_see_the_request
    assert_equal ["order-1"], @service.list(actor_user_id: "broker-1").map { |entry| entry.decision.order_id }
    assert_raises(ZeroXDA::Market::Core::Forbidden) do
      @service.list(actor_user_id: "client-1")
    end
    assert_raises(ZeroXDA::Market::Core::Forbidden) do
      @service.accept(actor_user_id: "broker-2", order_id: "order-1", expected_version: 0)
    end
  end

  def test_accept_is_idempotent_and_reports_only_the_first_transition_as_changed
    accepted = @service.accept(actor_user_id: "broker-1", order_id: "order-1", expected_version: 0)
    repeated = @service.accept(actor_user_id: "broker-1", order_id: "order-1", expected_version: 0)

    assert_equal "accepted", accepted.decision.status
    assert accepted.changed
    refute repeated.changed
  end

  def test_completion_requires_payment_then_finishes_the_manual_task_and_order
    accepted = @service.accept(actor_user_id: "broker-1", order_id: "order-1", expected_version: 0)
    error = assert_raises(ZeroXDA::Market::Core::Conflict) do
      @service.complete(
        actor_user_id: "broker-1",
        order_id: "order-1",
        expected_version: accepted.decision.version
      )
    end
    assert_equal "payment_required", error.code

    @kernel.order.payment["status"] = "confirmed"
    completed = @service.complete(
      actor_user_id: "broker-1",
      order_id: "order-1",
      expected_version: accepted.decision.version,
      data: { "delivery" => "test" }
    )

    assert_equal "completed", completed.decision.status
    assert_equal "succeeded", completed.order.status
    assert_equal [["task-1", "broker-1"]], @provider.claims
    assert_equal "test", @provider.completions.first.fetch(2).fetch("delivery")
  end
end
