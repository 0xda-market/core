# frozen_string_literal: true

require "minitest/autorun"
require "bigdecimal"
require_relative "../lib/zero_x_da/market/pricing/automatic_service"
require_relative "../lib/zero_x_da/market/pricing/competitive_reference_policy"
require_relative "../lib/zero_x_da/market/pricing/profitability_policy"

class AutomaticPricingServiceTest < Minitest::Test
  Product = Struct.new(:sku, :status, :marketable, keyword_init: true) do
    def marketable? = marketable
  end
  Listing = Struct.new(:seller_user_id, :price_amount, :currency, :available_quantity, keyword_init: true)
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
      raise ArgumentError, "stale FX" unless currency == "UAH"

      BigDecimal(amount.to_s) / 40
    end
  end

  class BrokenLocalization < Localization
    def amount_usdt(amount:, currency:)
      raise "unexpected adapter bug" if currency == "BUG"

      super
    end
  end

  class Pricing
    attr_reader :applied, :revision_reads

    def initialize(current = {}, revisions: [7])
      @current = current
      @revisions = revisions
      @revision_reads = 0
      @applied = []
    end

    def current_prices = @current

    def current_revision
      value = @revisions.fetch([@revision_reads, @revisions.length - 1].min)
      @revision_reads += 1
      value
    end

    def apply_prices(entries, source:, expected_revision:)
      @applied << [entries, source, expected_revision]
    end
  end

  def product(sku = "premium_3m")
    Product.new(sku: sku, status: "active", marketable: true)
  end

  def listing(price_amount:, currency: "USDT", seller_user_id: "broker-a", available_quantity: "1")
    Listing.new(
      seller_user_id: seller_user_id,
      price_amount: price_amount,
      currency: currency,
      available_quantity: BigDecimal(available_quantity)
    )
  end

  def reference_policy
    ZeroXDA::Market::Pricing::CompetitiveReferencePolicy.new(routing_headroom_bps: 500)
  end

  def profitability
    ZeroXDA::Market::Pricing::ProfitabilityPolicy.new(
      minimum_margin_bps: 100,
      supply_buffer_bps: 100
    )
  end

  def service(products:, rows:, current: {}, pricing: nil, localization: Localization.new)
    pricing ||= Pricing.new(current)
    subject = ZeroXDA::Market::Pricing::AutomaticService.new(
      catalog: Catalog.new(products),
      pricing: pricing,
      listings_store: Listings.new(rows),
      localization: localization,
      profitability: profitability,
      reference_policy: reference_policy
    )
    [subject, pricing]
  end

  def required_price_for(best_ask)
    reference = reference_policy.reference_supply_cost_usdt(cheapest_supply_cost_usdt: best_ask)
    profitability.minimum_client_unit_price_usdt(supply_unit_cost_usdt: reference, quantity: 1)
  end

  def test_prices_a_new_product_from_best_supply_with_broker_routing_headroom
    subject, pricing = service(
      products: [product],
      rows: {
        "premium_3m" => [
          listing(price_amount: "10", seller_user_id: "broker-a"),
          listing(price_amount: "440", currency: "UAH", seller_user_id: "broker-b")
        ]
      }
    )

    result = subject.reconcile.first

    assert_equal "priced", result.status
    assert_equal BigDecimal("10"), result.supply_cost_usdt
    assert_equal BigDecimal("10.5"), result.reference_supply_cost_usdt
    assert profitability.profitable?(
      client_total_usdt: result.price_usdt,
      supply_unit_cost_usdt: "10.5",
      quantity: 1
    )
    assert_equal 1, pricing.applied.length
    assert_equal "premium_3m", pricing.applied.first[0].first.fetch("sku")
    assert_equal "core", pricing.applied.first[1]
    assert_equal 7, pricing.applied.first[2]
  end

  def test_raises_an_insolvent_price_but_never_auto_reduces_a_profitable_price
    required = required_price_for("10")

    low_subject, low_pricing = service(
      products: [product],
      rows: { "premium_3m" => [listing(price_amount: "10")] },
      current: { "premium_3m" => Price.new(amount_usdt: required - BigDecimal("0.01")) }
    )
    assert_equal "raised", low_subject.reconcile.first.status
    refute_empty low_pricing.applied

    high_subject, high_pricing = service(
      products: [product],
      rows: { "premium_3m" => [listing(price_amount: "8")] },
      current: { "premium_3m" => Price.new(amount_usdt: BigDecimal("20")) }
    )
    result = high_subject.reconcile.first
    assert_equal "stable", result.status
    assert_equal BigDecimal("20"), result.price_usdt
    assert_empty high_pricing.applied
  end

  def test_sub_unit_supply_cannot_anchor_the_unit_pricing_floor
    subject, pricing = service(
      products: [product],
      rows: {
        "premium_3m" => [
          listing(price_amount: "1", available_quantity: "0.2"),
          listing(price_amount: "10", seller_user_id: "broker-b", available_quantity: "1")
        ]
      }
    )

    result = subject.reconcile.first

    assert_equal BigDecimal("10"), result.supply_cost_usdt
    refute_empty pricing.applied
  end

  def test_stale_or_unsupported_fx_is_excluded_but_unexpected_adapter_errors_surface
    stale_subject, = service(
      products: [product],
      rows: {
        "premium_3m" => [
          listing(price_amount: "10", currency: "EUR"),
          listing(price_amount: "11", seller_user_id: "broker-b")
        ]
      }
    )
    assert_equal BigDecimal("11"), stale_subject.reconcile.first.supply_cost_usdt

    broken_subject, = service(
      products: [product],
      rows: { "premium_3m" => [listing(price_amount: "10", currency: "BUG")] },
      localization: BrokenLocalization.new
    )
    assert_raises(RuntimeError) { broken_subject.reconcile }
  end

  def test_price_application_uses_the_revision_captured_before_the_price_snapshot
    pricing = Pricing.new({}, revisions: [7, 8])
    subject, = service(
      products: [product],
      rows: { "premium_3m" => [listing(price_amount: "10")] },
      pricing: pricing
    )

    subject.reconcile

    assert_equal 1, pricing.revision_reads
    assert_equal 7, pricing.applied.first[2]
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
