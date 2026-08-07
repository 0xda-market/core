# frozen_string_literal: true

require "minitest/autorun"
require "bigdecimal"
require_relative "../lib/zero_x_da/market/pricing/automatic_service"
require_relative "../lib/zero_x_da/market/pricing/profitability_policy"

class AutomaticPricingServiceTest < Minitest::Test
  Product = Struct.new(:sku, :status, :marketable, keyword_init: true) do
    def marketable? = marketable
  end
  Listing = Struct.new(:price_amount, :currency, keyword_init: true)
  Price = Struct.new(:amount_usdt, keyword_init: true)

  class Catalog
    def initialize(products) = @products = products
    def admin_products(locale:) = @products
  end

  class Listings
    def initialize(rows) = @rows = rows
    def available_listings(sku:) = @rows.fetch(sku, [])
  end

  class Localization
    def amount_usdt(amount:, currency:)
      raise "stale FX" unless currency == "UAH"
      BigDecimal(amount.to_s) / 40
    end
  end

  class Pricing
    attr_reader :applied
    def initialize(current = {})
      @current = current
      @applied = []
    end
    def current_prices = @current
    def current_revision = 7
    def apply_prices(entries, source:, expected_revision:)
      @applied << [entries, source, expected_revision]
    end
  end

  def product(sku = "premium_3m")
    Product.new(sku: sku, status: "active", marketable: true)
  end

  def service(products:, rows:, current: {})
    pricing = Pricing.new(current)
    subject = ZeroXDA::Market::Pricing::AutomaticService.new(
      catalog: Catalog.new(products), pricing: pricing, listings_store: Listings.new(rows),
      localization: Localization.new,
      profitability: ZeroXDA::Market::Pricing::ProfitabilityPolicy.new(
        minimum_margin_bps: 100, supply_buffer_bps: 100
      )
    )
    [subject, pricing]
  end

  def test_prices_a_new_product_from_the_cheapest_broker_ask
    subject, pricing = service(
      products: [product],
      rows: { "premium_3m" => [Listing.new(price_amount: "10", currency: "USDT"),
                                  Listing.new(price_amount: "440", currency: "UAH")] }
    )

    result = subject.reconcile.first

    assert_equal "priced", result.status
    assert_equal BigDecimal("10"), result.supply_cost_usdt
    assert_equal 1, pricing.applied.length
    assert_equal "premium_3m", pricing.applied.first[0].first.fetch("sku")
    assert_equal "core", pricing.applied.first[1]
    assert_equal 7, pricing.applied.first[2]
  end

  def test_raises_an_insolvent_price_but_never_auto_reduces_a_profitable_price
    floor_policy = ZeroXDA::Market::Pricing::ProfitabilityPolicy.new(minimum_margin_bps: 100, supply_buffer_bps: 100)
    required = floor_policy.minimum_client_unit_price_usdt(supply_unit_cost_usdt: "10", quantity: 1)

    low_subject, low_pricing = service(
      products: [product], rows: { "premium_3m" => [Listing.new(price_amount: "10", currency: "USDT")] },
      current: { "premium_3m" => Price.new(amount_usdt: required - BigDecimal("0.01")) }
    )
    assert_equal "raised", low_subject.reconcile.first.status
    refute_empty low_pricing.applied

    high_subject, high_pricing = service(
      products: [product], rows: { "premium_3m" => [Listing.new(price_amount: "8", currency: "USDT")] },
      current: { "premium_3m" => Price.new(amount_usdt: BigDecimal("20")) }
    )
    result = high_subject.reconcile.first
    assert_equal "stable", result.status
    assert_equal BigDecimal("20"), result.price_usdt
    assert_empty high_pricing.applied
  end

  def test_product_without_supply_remains_unpriced
    subject, pricing = service(products: [product], rows: {})

    result = subject.reconcile.first

    assert_equal "awaiting_supply", result.status
    assert_nil result.price_usdt
    assert_empty pricing.applied
  end

  def test_ignores_inactive_and_non_marketable_catalog_rows
    subject, = service(
      products: [Product.new(sku: "inactive", status: "inactive", marketable: true),
                 Product.new(sku: "USD", status: "active", marketable: false)],
      rows: {}
    )

    assert_empty subject.reconcile
  end
end
