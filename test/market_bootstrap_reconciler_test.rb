# frozen_string_literal: true

require_relative "test_helper"
require "bigdecimal"
require "zero_x_da/market/bootstrap/reconciler"

class MarketBootstrapReconcilerTest < Minitest::Test
  Price = Struct.new(:amount_usdt)
  Listing = Struct.new(:id, :sku, :quantity, :price_amount, :currency, :version, keyword_init: true)

  class Pricing
    attr_reader :applications

    def initialize(prices = {})
      @prices = prices
      @applications = []
      @revision = 7
    end

    def current_prices
      @prices
    end

    def current_revision
      @revision
    end

    def apply_prices(entries, **options)
      @applications << [entries, options]
      entries.each { |entry| @prices[entry.fetch("sku")] = Price.new(BigDecimal(entry.fetch("amount_usdt"))) }
      @revision += 1
      []
    end
  end

  class Listings
    attr_reader :created, :updated

    def initialize(rows = [])
      @rows = rows
      @created = []
      @updated = []
    end

    def list_owned(actor_user_id:)
      @actor_user_id = actor_user_id
      @rows
    end

    def create(**attributes)
      @created << attributes
      @rows << Listing.new(
        id: "created-#{@rows.length}",
        sku: attributes.fetch(:sku),
        quantity: BigDecimal(attributes.fetch(:quantity)),
        price_amount: BigDecimal(attributes.fetch(:price_amount)),
        currency: attributes.fetch(:currency),
        version: 0
      )
    end

    def update(**attributes)
      @updated << attributes
      row = @rows.find { |candidate| candidate.id == attributes.fetch(:listing_id) }
      row.quantity = BigDecimal(attributes.fetch(:quantity))
      row.price_amount = BigDecimal(attributes.fetch(:price_amount))
      row.currency = attributes.fetch(:currency)
      row.version += 1
    end
  end

  def test_reconciles_only_the_diff_and_is_idempotent
    manifest = manifest()
    pricing = Pricing.new("premium_3m" => Price.new(BigDecimal("13")))
    listings = Listings.new([
      Listing.new(
        id: "listing-1", sku: "premium_3m", quantity: BigDecimal("10"),
        price_amount: BigDecimal("12"), currency: "USDT", version: 3
      ),
      Listing.new(
        id: "listing-2", sku: "premium_6m", quantity: BigDecimal("5"),
        price_amount: BigDecimal("16"), currency: "USDT", version: 1
      )
    ])
    reconciler = ZeroXDA::Market::Bootstrap::Reconciler.new(
      pricing: pricing,
      listings: listings,
      actor_user_id: "broker-1"
    )

    first = reconciler.reconcile(manifest)
    assert_equal 5, first.dig("prices", "changed")
    assert_equal %w[premium_3m], first.dig("listings", "unchanged")
    assert_equal %w[premium_6m], first.dig("listings", "updated")
    assert_equal 4, first.dig("listings", "created").length
    assert_equal "broker-1", listings.updated.first.fetch(:actor_user_id)
    assert_equal 1, pricing.applications.length

    second = reconciler.reconcile(manifest)
    assert_equal 0, second.dig("prices", "changed")
    assert_equal [], second.dig("listings", "created")
    assert_equal [], second.dig("listings", "updated")
    assert_equal 6, second.dig("listings", "unchanged").length
    assert_equal 1, pricing.applications.length
  end

  def test_rejects_incomplete_manifests_before_writing
    pricing = Pricing.new
    listings = Listings.new
    reconciler = ZeroXDA::Market::Bootstrap::Reconciler.new(
      pricing: pricing,
      listings: listings,
      actor_user_id: "broker-1"
    )

    error = assert_raises(ArgumentError) do
      reconciler.reconcile("products" => manifest.fetch("products").first(5))
    end
    assert_match(/missing skus/, error.message)
    assert_empty pricing.applications
    assert_empty listings.created
  end

  def test_refuses_multiple_active_listings_for_one_sku
    pricing = Pricing.new(all_prices)
    duplicate = Listing.new(
      id: "listing-1", sku: "premium_3m", quantity: BigDecimal("10"),
      price_amount: BigDecimal("12"), currency: "USDT", version: 0
    )
    listings = Listings.new([duplicate, duplicate.dup.tap { |row| row.id = "listing-2" }])
    reconciler = ZeroXDA::Market::Bootstrap::Reconciler.new(
      pricing: pricing,
      listings: listings,
      actor_user_id: "broker-1"
    )

    error = assert_raises(ArgumentError) { reconciler.reconcile(manifest) }
    assert_match(/multiple active broker listings/, error.message)
  end

  private

  def manifest
    {
      "products" => [
        product("premium_3m", "13", "12"),
        product("premium_6m", "18", "17"),
        product("premium_9m", "24", "23"),
        product("stars_500", "9", "8"),
        product("stars_1000", "17", "16"),
        product("stars_3000", "49", "47")
      ]
    }
  end

  def all_prices
    manifest.fetch("products").to_h do |row|
      [row.fetch("sku"), Price.new(BigDecimal(row.fetch("sale_price_usdt")))]
    end
  end

  def product(sku, sale_price, ask)
    {
      "sku" => sku,
      "sale_price_usdt" => sale_price,
      "supply" => { "quantity" => "10", "price_amount" => ask, "currency" => "USDT" }
    }
  end
end
