# frozen_string_literal: true

require_relative "test_helper"
require "bigdecimal"
require "json"
require "rack/mock"
require "zero_x_da/market/catalog/product"
require "zero_x_da/market/transport/json_api"

class WebAppBootstrapAPITest < Minitest::Test
  Price = Struct.new(:amount_usdt, :source, :set_by_user_id, :created_at, keyword_init: true)

  class Catalog
    attr_reader :locales

    def initialize(products)
      @products = products
      @locales = []
    end

    def products(locale:)
      @locales << locale
      @products
    end
  end

  class Pricing
    def initialize(prices)
      @prices = prices
    end

    def current_prices
      @prices
    end
  end

  class Listings
    def initialize(price_floors)
      @price_floors = price_floors
    end

    def maximum_available_prices_usdt
      @price_floors
    end
  end

  class Localization
    def locale_for(value)
      value.to_s == "uk_UA" ? "uk_UA" : "en_US"
    end

    def supported_currency?(value)
      value == "USDT"
    end

    def convert(amount_usdt:, currency:)
      raise ArgumentError, "unsupported test currency" unless currency == "USDT"

      amount_usdt
    end
  end

  def setup
    now = Time.utc(2026, 7, 31, 17, 0, 0)
    product = ZeroXDA::Market::Catalog::Product.new(
      sku: "premium_3m",
      short_name: "Premium 3m",
      name: "Telegram Premium 3 months",
      button_label: "Premium 3 months",
      locale: "uk_UA",
      metadata: { "category" => "telegram-premium" },
      status: "active",
      position: 1,
      updated_by_user_id: "internal-editor-id",
      price_updated_by_user_id: "internal-price-editor-id",
      price_updated_at: now,
      created_at: now
    )
    @catalog = Catalog.new([product])
    @pricing = Pricing.new(
      "premium_3m" => Price.new(
        amount_usdt: BigDecimal("13.25"),
        source: "admin",
        set_by_user_id: "internal-price-editor-id",
        created_at: now
      )
    )
    @localization = Localization.new
    @listings = Listings.new("premium_3m" => BigDecimal("9.25"))
    @client = build_client
  end

  def test_returns_the_complete_catalog_without_server_pagination
    response = @client.get("/v1/webapp/bootstrap?locale=uk_UA&currency=USDT")

    assert_equal 200, response.status
    document = JSON.parse(response.body)
    assert_equal true, document.dig("meta", "complete")
    assert_equal "client", document.dig("meta", "pagination")
    assert_equal 1, document.dig("meta", "count")
    assert_equal 1, document.dig("meta", "available_count")
    assert_equal "uk_UA", document.dig("meta", "locale")
    assert_equal "USDT", document.dig("meta", "currency")

    product = document.fetch("data").first
    assert_equal "premium_3m", product.fetch("id")
    assert_equal true, product.dig("attributes", "available")
    assert_equal "13.25", product.dig("attributes", "price", "amount")
    refute product.fetch("attributes").key?("updated_by_user_id")
    refute product.fetch("attributes").key?("price_updated_by_user_id")
    refute product.dig("attributes", "price").key?("edited_by_user_id")
    assert_equal ["uk_UA"], @catalog.locales
  end

  def test_hides_a_client_price_without_active_broker_liquidity
    client = build_client(listings: Listings.new({}))

    document = JSON.parse(client.get("/v1/webapp/bootstrap?locale=uk_UA&currency=USDT").body)
    product = document.fetch("data").first

    assert_equal false, product.dig("attributes", "available")
    assert_nil product.dig("attributes", "price")
    assert_equal 0, document.dig("meta", "available_count")
  end

  def test_hides_liquidity_without_an_applied_client_price
    client = build_client(pricing: Pricing.new({}))

    document = JSON.parse(client.get("/v1/webapp/bootstrap?locale=uk_UA&currency=USDT").body)
    product = document.fetch("data").first

    assert_equal false, product.dig("attributes", "available")
    assert_nil product.dig("attributes", "price")
    assert_equal 0, document.dig("meta", "available_count")
  end

  def test_exposes_a_product_only_after_price_and_broker_liquidity_are_both_current
    prices = {}
    price_floors = {}
    client = build_client(
      pricing: Pricing.new(prices),
      listings: Listings.new(price_floors)
    )

    unavailable = JSON.parse(client.get("/v1/webapp/bootstrap?locale=uk_UA&currency=USDT").body)
    assert_equal false, unavailable.dig("data", 0, "attributes", "available")

    price_floors["premium_3m"] = BigDecimal("9.25")
    liquidity_only = JSON.parse(client.get("/v1/webapp/bootstrap?locale=uk_UA&currency=USDT").body)
    assert_equal false, liquidity_only.dig("data", 0, "attributes", "available")

    prices["premium_3m"] = Price.new(
      amount_usdt: BigDecimal("13.25"),
      source: "admin",
      set_by_user_id: "internal-price-editor-id",
      created_at: Time.utc(2026, 7, 31, 17, 0, 0)
    )
    available = JSON.parse(client.get("/v1/webapp/bootstrap?locale=uk_UA&currency=USDT").body)
    assert_equal true, available.dig("data", 0, "attributes", "available")
    assert_equal "13.25", available.dig("data", 0, "attributes", "price", "amount")
  end

  def test_never_exposes_a_price_below_the_highest_active_listing
    client = build_client(
      listings: Listings.new("premium_3m" => BigDecimal("14.75"))
    )

    public_document = JSON.parse(
      client.get("/v1/webapp/bootstrap?locale=uk_UA&currency=USDT").body
    )
    public_price = public_document.dig("data", 0, "attributes", "price")
    assert_equal "14.75", public_price.fetch("amount")
    assert_equal "14.75", public_price.fetch("amount_usdt")
    refute public_price.key?("edited_by_user_id")

    protected_response = client.get(
      "/v1/products?locale=uk_UA&currency=USDT",
      "HTTP_AUTHORIZATION" => "Bearer protected-token"
    )
    assert_equal 200, protected_response.status
    protected_price = JSON.parse(protected_response.body).dig("data", 0, "attributes", "price")
    assert_equal "14.75", protected_price.fetch("amount")
    assert_equal "14.75", protected_price.fetch("amount_usdt")
  end

  def test_snapshot_identifier_is_stable_for_identical_catalog_data
    first = JSON.parse(@client.get("/v1/webapp/bootstrap?locale=uk_UA&currency=USDT").body)
    second = JSON.parse(@client.get("/v1/webapp/bootstrap?locale=uk_UA&currency=USDT").body)

    assert_equal first.dig("meta", "snapshot_id"), second.dig("meta", "snapshot_id")
  end

  def test_existing_product_endpoint_remains_protected
    response = @client.get("/v1/products?locale=uk_UA&currency=USDT")

    assert_equal 401, response.status
  end

  private

  def build_client(pricing: @pricing, listings: @listings)
    Rack::MockRequest.new(
      ZeroXDA::Market::Transport::JSONAPI.new(
        kernel: Object.new,
        token: "protected-token",
        catalog: @catalog,
        pricing: pricing,
        localization: @localization,
        listings: listings
      )
    )
  end
end
