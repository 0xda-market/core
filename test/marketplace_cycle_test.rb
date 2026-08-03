# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "rack/mock"
require "zero_x_da/market/catalog/memory_store"
require "zero_x_da/market/catalog/product"
require "zero_x_da/market/catalog/service"
require "zero_x_da/market/identity/memory_store"
require "zero_x_da/market/identity/service"
require "zero_x_da/market/listings/memory_store"
require "zero_x_da/market/listings/service"
require "zero_x_da/market/marketplace/service"
require "zero_x_da/market/pricing/memory_store"
require "zero_x_da/market/pricing/service"
require "zero_x_da/market/transport/json_api"

class MarketplaceCycleTest < Minitest::Test
  include KernelFixture

  def setup
    @clock = MutableClock.new
    @users = ZeroXDA::Market::Identity::MemoryStore.new
    identity = ZeroXDA::Market::Identity::Service.new(
      store: @users,
      clock: @clock,
      id_generator: SequenceIDs.new
    )
    @broker = identity.authenticate(provider: "telegram", provider_user_id: "77", role: "broker").user
    @client = identity.authenticate(provider: "telegram", provider_user_id: "79").user
    products = [
      product("premium_3m", marketable: true, position: 1),
      product(
        "usdt",
        marketable: false,
        position: 100,
        metadata: { family: "currency", code: "USDT" }
      )
    ]
    @catalog = ZeroXDA::Market::Catalog::Service.new(
      store: ZeroXDA::Market::Catalog::MemoryStore.new(products: products),
      clock: @clock
    )
    @pricing = ZeroXDA::Market::Pricing::Service.new(
      store: ZeroXDA::Market::Pricing::MemoryStore.new,
      catalog: @catalog,
      clock: @clock
    )
    @pricing.apply_price(sku: "premium_3m", amount_usdt: "12.5")
    @listings = ZeroXDA::Market::Listings::Service.new(
      store: ZeroXDA::Market::Listings::MemoryStore.new,
      users: @users,
      catalog: @catalog,
      clock: @clock,
      id_generator: SequenceIDs.new
    )
    @listing = @listings.create(
      actor_user_id: @broker.id,
      sku: "premium_3m",
      quantity: "3",
      price_amount: "9.25",
      currency: "USDT"
    )
    provider = TestProvider.new(clock: @clock, quote_ttl: 60)
    @kernel, = build_kernel(
      provider: provider,
      clock: @clock,
      capability: "manual.fulfillment"
    )
    @marketplace = ZeroXDA::Market::Marketplace::Service.new(
      kernel: @kernel,
      catalog: @catalog,
      pricing: @pricing,
      listings: @listings
    )
  end

  def test_keeps_inventory_reserved_until_payment_is_confirmed
    quoted = @marketplace.quote(
      customer_user_id: @client.id,
      sku: "premium_3m",
      quantity: "1",
      context: { channel: "telegram" }
    )

    assert_equal BigDecimal("12.5"), quoted.unit_price_usdt
    assert_equal BigDecimal("12.5"), quoted.total_price_usdt
    assert_equal @listing.id, quoted.reservation.listing_id
    assert_equal BigDecimal("9.25"), quoted.reservation.supply_unit_price
    assert_equal "active", quoted.reservation.status
    reserved_listing = @listings.list_owned(actor_user_id: @broker.id).fetch(0)
    assert_equal BigDecimal("2"), reserved_listing.available_quantity
    assert_equal BigDecimal("1"), reserved_listing.reserved_quantity

    accepted = @marketplace.accept(
      customer_user_id: @client.id,
      quote_id: quoted.quote.id
    )
    assert_equal "payment_pending", accepted.order.status
    assert_equal "pending", accepted.order.payment.fetch("status")
    assert_equal "12.5", accepted.order.payment.fetch("amount")
    assert_equal "USDT", accepted.order.payment.fetch("currency")
    assert_equal "payment_pending", accepted.reservation.status
    pending_listing = @listings.list_owned(actor_user_id: @broker.id).fetch(0)
    assert_equal BigDecimal("2"), pending_listing.available_quantity
    assert_equal BigDecimal("1"), pending_listing.reserved_quantity
    assert_equal BigDecimal("0"), pending_listing.sold_quantity

    error = assert_raises(ZeroXDA::Market::Core::Conflict) do
      @marketplace.execute_order(
        customer_user_id: @client.id,
        order_id: accepted.order.id
      )
    end
    assert_equal "payment_required", error.code

    confirmed = @marketplace.confirm_payment(
      order_id: accepted.order.id,
      reference: "payment-1",
      data: { provider: "test" }
    )
    assert_equal "succeeded", confirmed.order.status
    assert_equal "confirmed", confirmed.order.payment.fetch("status")
    assert_equal "payment-1", confirmed.order.payment.fetch("reference")
    assert_equal "committed", confirmed.reservation.status
    committed_listing = @listings.list_owned(actor_user_id: @broker.id).fetch(0)
    assert_equal BigDecimal("2"), committed_listing.available_quantity
    assert_equal BigDecimal("0"), committed_listing.reserved_quantity
    assert_equal BigDecimal("1"), committed_listing.sold_quantity

    repeated = @marketplace.confirm_payment(
      order_id: accepted.order.id,
      reference: "payment-1",
      data: { provider: "test" }
    )
    assert_equal confirmed.order.id, repeated.order.id
    assert_equal BigDecimal("1"), @listings.list_owned(actor_user_id: @broker.id).fetch(0).sold_quantity
  end

  def test_rejects_overselling_and_releases_expired_quote_inventory
    error = assert_raises(ZeroXDA::Market::Core::Conflict) do
      @marketplace.quote(
        customer_user_id: @client.id,
        sku: "premium_3m",
        quantity: "4"
      )
    end
    assert_equal "insufficient_liquidity", error.code
    assert_equal BigDecimal("3"), @listings.list_owned(actor_user_id: @broker.id).fetch(0).available_quantity

    quoted = @marketplace.quote(
      customer_user_id: @client.id,
      sku: "premium_3m",
      quantity: "2"
    )
    assert_equal BigDecimal("1"), @listings.list_owned(actor_user_id: @broker.id).fetch(0).available_quantity

    @clock.advance(61)
    assert_raises(ZeroXDA::Market::Core::QuoteExpired) do
      @marketplace.accept(customer_user_id: @client.id, quote_id: quoted.quote.id)
    end
    assert_equal ["premium_3m"], @listings.available_skus
    released = @listings.list_owned(actor_user_id: @broker.id).fetch(0)
    assert_equal BigDecimal("3"), released.available_quantity
    assert_equal BigDecimal("0"), released.reserved_quantity
  end

  def test_marketplace_api_exposes_payment_state_without_supply_economics
    api = ZeroXDA::Market::Transport::JSONAPI.new(
      kernel: @kernel,
      catalog: @catalog,
      pricing: @pricing,
      listings: @listings,
      marketplace: @marketplace
    )
    client = Rack::MockRequest.new(api)

    quote_response = request_json(
      client,
      "POST",
      "/v1/market/quotes",
      actor_user_id: @client.id,
      sku: "premium_3m",
      quantity: "1",
      context: { channel: "telegram" }
    )
    assert_equal 201, quote_response.status, quote_response.body
    quote_document = JSON.parse(quote_response.body)
    quote_id = quote_document.dig("data", "id")
    attributes = quote_document.dig("data", "attributes")
    assert_equal "12.5", attributes.fetch("total_price_usdt")
    assert_equal "active", attributes.fetch("inventory_status")
    refute attributes.key?("seller_user_id")
    refute attributes.key?("listing_id")
    refute attributes.key?("supply_unit_price")
    refute attributes.key?("supply_currency")
    refute_includes quote_response.body, "9.25"

    order_response = request_json(
      client,
      "POST",
      "/v1/market/quotes/#{quote_id}/accept",
      actor_user_id: @client.id
    )
    assert_equal 201, order_response.status, order_response.body
    order_document = JSON.parse(order_response.body)
    order_attributes = order_document.dig("data", "attributes")
    assert_equal "payment_pending", order_attributes.fetch("status")
    assert_equal "payment_pending", order_attributes.fetch("inventory_status")
    assert_equal "pending", order_attributes.fetch("payment_status")
    assert_equal "12.5", order_attributes.dig("payment", "amount")
    refute order_attributes.key?("seller_user_id")
    refute order_attributes.key?("listing_id")
    refute order_attributes.key?("supply_unit_price")
  end

  private

  def product(sku, marketable:, position:, metadata: {})
    ZeroXDA::Market::Catalog::Product.new(
      sku: sku,
      short_name: sku,
      name: sku,
      button_label: sku,
      metadata: metadata,
      marketable: marketable,
      position: position,
      created_at: @clock.call
    )
  end

  def request_json(client, method, path, document)
    client.request(
      method,
      path,
      "CONTENT_TYPE" => "application/json",
      input: JSON.generate(document)
    )
  end
end
