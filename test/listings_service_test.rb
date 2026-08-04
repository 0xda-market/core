# frozen_string_literal: true

require_relative "test_helper"
require "zero_x_da/market/catalog/memory_store"
require "zero_x_da/market/catalog/product"
require "zero_x_da/market/catalog/service"
require "zero_x_da/market/identity/memory_store"
require "zero_x_da/market/identity/admin_service"
require "zero_x_da/market/identity/service"
require "zero_x_da/market/listings/memory_store"
require "zero_x_da/market/listings/service"

class ListingsServiceTest < Minitest::Test
  def setup
    @clock = MutableClock.new
    @users = ZeroXDA::Market::Identity::MemoryStore.new
    identities = ZeroXDA::Market::Identity::Service.new(
      store: @users,
      clock: @clock,
      id_generator: SequenceIDs.new
    )
    @broker = identities.authenticate(provider: "telegram", provider_user_id: 77, role: "broker").user
    @other_broker = identities.authenticate(provider: "telegram", provider_user_id: 78, role: "broker").user
    @client = identities.authenticate(provider: "telegram", provider_user_id: 79).user
    products = [
      product("btc", marketable: true, position: 1),
      product("usdt", marketable: false, position: 100, metadata: { family: "currency", code: "USDT" }),
      product("uah", marketable: false, position: 101, metadata: { family: "currency", code: "UAH" })
    ]
    @catalog = ZeroXDA::Market::Catalog::Service.new(
      store: ZeroXDA::Market::Catalog::MemoryStore.new(products: products)
    )
    @service = ZeroXDA::Market::Listings::Service.new(
      store: ZeroXDA::Market::Listings::MemoryStore.new,
      users: @users,
      catalog: @catalog,
      clock: @clock,
      id_generator: SequenceIDs.new
    )
  end

  def test_creates_updates_lists_and_withdraws_an_owned_listing
    listing = create_listing

    assert_equal "btc", listing.sku
    assert_equal BigDecimal("0.125"), listing.quantity
    assert_equal listing.quantity, listing.available_quantity
    assert_equal BigDecimal("0"), listing.reserved_quantity
    assert_equal BigDecimal("0"), listing.sold_quantity
    assert_equal BigDecimal("65000.12345678"), listing.price_amount
    assert_equal [listing], @service.list_owned(actor_user_id: @broker.id)

    @clock.advance(1)
    updated = @service.update(
      actor_user_id: @broker.id,
      listing_id: listing.id,
      quantity: "0.25",
      price_amount: "64900",
      currency: "UAH",
      expected_version: 0
    )
    assert_equal 1, updated.version
    assert_equal "UAH", updated.currency
    assert_equal BigDecimal("0.25"), updated.available_quantity

    withdrawn = @service.withdraw(
      actor_user_id: @broker.id,
      listing_id: listing.id,
      expected_version: 1
    )
    assert_equal "withdrawn", withdrawn.status
    assert_empty @service.list_owned(actor_user_id: @broker.id)
  end

  def test_reserves_commits_and_releases_finite_inventory
    listing = @service.create(
      actor_user_id: @broker.id,
      sku: "btc",
      quantity: "3",
      price_amount: "65000",
      currency: "USDT"
    )

    reservation = @service.reserve(
      customer_user_id: @client.id,
      quote_id: "quote-1",
      sku: "btc",
      quantity: "1",
      expires_at: @clock.call + 60
    )
    reserved = @service.list_owned(actor_user_id: @broker.id).fetch(0)
    assert_equal listing.id, reservation.listing_id
    assert_equal BigDecimal("2"), reserved.available_quantity
    assert_equal BigDecimal("1"), reserved.reserved_quantity
    assert_equal BigDecimal("0"), reserved.sold_quantity
    assert_equal BigDecimal("65000"), reservation.supply_unit_price

    committed = @service.commit(
      customer_user_id: @client.id,
      quote_id: "quote-1",
      order_id: "order-1"
    )
    sold = @service.list_owned(actor_user_id: @broker.id).fetch(0)
    assert_equal "committed", committed.status
    assert_equal BigDecimal("2"), sold.available_quantity
    assert_equal BigDecimal("0"), sold.reserved_quantity
    assert_equal BigDecimal("1"), sold.sold_quantity

    error = assert_raises(ZeroXDA::Market::Core::Conflict) do
      @service.update(
        actor_user_id: @broker.id,
        listing_id: listing.id,
        quantity: "0.5",
        price_amount: "64000",
        currency: "USDT",
        expected_version: sold.version
      )
    end
    assert_equal "inventory_already_committed", error.code

    @service.reserve(
      customer_user_id: @client.id,
      quote_id: "quote-2",
      sku: "btc",
      quantity: "1",
      expires_at: @clock.call + 30
    )
    @clock.advance(31)
    assert_equal ["btc"], @service.available_skus
    released = @service.list_owned(actor_user_id: @broker.id).fetch(0)
    assert_equal BigDecimal("2"), released.available_quantity
    assert_equal BigDecimal("0"), released.reserved_quantity
    assert_equal BigDecimal("1"), released.sold_quantity
    assert_equal "released", @service.reservation_for_quote("quote-2").status
  end

  def test_rejects_clients_and_cross_user_mutation
    assert_raises(ZeroXDA::Market::Core::Forbidden) do
      @service.list_owned(actor_user_id: @client.id)
    end

    listing = create_listing
    assert_raises(ZeroXDA::Market::Core::Forbidden) do
      @service.withdraw(
        actor_user_id: @other_broker.id,
        listing_id: listing.id,
        expected_version: 0
      )
    end
  end

  def test_admin_inherits_broker_listing_capability
    admin = ZeroXDA::Market::Identity::AdminService.new(
      store: @users,
      clock: @clock
    ).bootstrap(user_id: @other_broker.id).user

    listing = @service.create(
      actor_user_id: admin.id,
      sku: "btc",
      quantity: "1",
      price_amount: "65000",
      currency: "USDT"
    )

    assert_equal admin.id, listing.seller_user_id
    assert_equal [listing], @service.list_owned(actor_user_id: admin.id)
  end

  def test_enforces_one_active_listing_per_asset_and_currency
    create_listing

    error = assert_raises(ZeroXDA::Market::Core::Conflict) { create_listing }
    assert_equal "duplicate_active_listing", error.code
  end

  def test_computes_the_highest_active_listing_as_the_client_price_floor
    lower = create_listing
    higher = @service.create(
      actor_user_id: @other_broker.id,
      sku: "btc",
      quantity: "0.25",
      price_amount: "66000.12345678",
      currency: "USDT"
    )

    assert_equal(
      BigDecimal("66000.123457"),
      @service.maximum_available_prices_usdt.fetch("btc")
    )

    @service.withdraw(
      actor_user_id: @other_broker.id,
      listing_id: higher.id,
      expected_version: higher.version
    )
    assert_equal(
      BigDecimal("65000.123457"),
      @service.maximum_available_prices_usdt.fetch("btc")
    )
    assert_equal lower.id, @service.list_owned(actor_user_id: @broker.id).fetch(0).id
  end

  def test_rejects_a_stale_client_price_before_reserving_inventory
    listing = @service.create(
      actor_user_id: @broker.id,
      sku: "btc",
      quantity: "1",
      price_amount: "10.00000001",
      currency: "USDT"
    )

    error = assert_raises(ZeroXDA::Market::Core::Conflict) do
      @service.reserve(
        customer_user_id: @client.id,
        quote_id: "quote-stale",
        sku: "btc",
        quantity: "1",
        expires_at: @clock.call + 60,
        client_unit_price_usdt: "10"
      )
    end

    assert_equal "client_price_stale", error.code
    unchanged = @service.list_owned(actor_user_id: @broker.id).fetch(0)
    assert_equal listing.quantity, unchanged.available_quantity
    assert_equal BigDecimal("0"), unchanged.reserved_quantity
  end

  def test_rejects_precision_beyond_storage_contract
    error = assert_raises(ArgumentError) do
      @service.create(
        actor_user_id: @broker.id,
        sku: "btc",
        quantity: "0.0000000000001",
        price_amount: "65000",
        currency: "USDT"
      )
    end
    assert_includes error.message, "12 fractional digits"
  end

  private

  def create_listing
    @service.create(
      actor_user_id: @broker.id,
      sku: "btc",
      quantity: "0.125",
      price_amount: "65000.12345678",
      currency: "USDT"
    )
  end

  def product(sku, marketable:, position:, metadata: {})
    ZeroXDA::Market::Catalog::Product.new(
      sku: sku,
      short_name: sku.upcase,
      name: sku.upcase,
      button_label: sku.upcase,
      metadata: metadata,
      marketable: marketable,
      position: position,
      created_at: @clock.call
    )
  end
end
