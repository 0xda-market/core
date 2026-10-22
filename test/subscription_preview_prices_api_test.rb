# frozen_string_literal: true
# © 2026 aiaiaiai · aiaiaiai.org

require_relative "test_helper"
require "rack/mock"
require "zero_x_da/market/catalog/memory_store"
require "zero_x_da/market/catalog/product"
require "zero_x_da/market/catalog/service"
require "zero_x_da/market/pricing/price"
require "zero_x_da/market/transport/json_api"

class SubscriptionPreviewPricesAPITest < Minitest::Test
  include KernelFixture

  def setup
    now = Time.utc(2026, 10, 22)
    @kernel, = build_kernel(provider: TestProvider.new(clock: MutableClock.new), clock: MutableClock.new)
    products = [
      ZeroXDA::Market::Catalog::Product.new(
        sku: "0x1_special_1m", name: "Special 1 month", button_label: "Special 1m",
        status: "inactive", position: 1,
        metadata: { "family" => "0x1_subscription", "tier" => "special",
                    "duration_months" => 1,
                    "seed_price" => { "currency" => "seeds", "amount" => 400, "symbol" => "₴€£" } },
        created_at: now
      ),
      ZeroXDA::Market::Catalog::Product.new(
        sku: "0x1_exclusive_1m", name: "Exclusive 1 month", button_label: "Exclusive 1m",
        status: "inactive", position: 2,
        metadata: { "family" => "0x1_subscription", "tier" => "exclusive", "duration_months" => 1 },
        created_at: now
      ),
      ZeroXDA::Market::Catalog::Product.new(
        sku: "premium_3m", name: "Premium", button_label: "Premium",
        position: 3, metadata: { "family" => "telegram_premium" }, created_at: now
      )
    ]
    @catalog = ZeroXDA::Market::Catalog::Service.new(
      store: ZeroXDA::Market::Catalog::MemoryStore.new(products: products)
    )
    price = ZeroXDA::Market::Pricing::Price.new(
      sku: "0x1_special_1m", amount_usdt: "2.49",
      source: "core", created_at: now
    )
    @pricing = Struct.new(:current_prices).new({ "0x1_special_1m" => price })
    @headers = { "HTTP_AUTHORIZATION" => "Bearer test-token" }
  end

  def test_preview_price_is_display_only_and_does_not_publish_the_subscription
    document = get_document(localization: nil, query: "currency=USDT&preview_0x1=true")
    special = document.fetch("data").find { |item| item["id"] == "0x1_special_1m" }.fetch("attributes")
    exclusive = document.fetch("data").find { |item| item["id"] == "0x1_exclusive_1m" }.fetch("attributes")
    regular = document.fetch("data").find { |item| item["id"] == "premium_3m" }.fetch("attributes")

    assert_equal true, special.fetch("preview")
    assert_equal false, special.fetch("available")
    assert_nil special.fetch("price")
    assert_equal "2.49", special.dig("preview_price", "amount_usdt")
    assert_equal "USDT", special.dig("preview_price", "currency")
    assert_equal 400, special.dig("metadata", "seed_price", "amount")
    assert_nil exclusive.fetch("preview_price")
    refute regular.key?("preview_price")

    normal = get_document(localization: nil, query: "currency=USDT")
    assert_equal ["premium_3m"], normal.fetch("data").map { |item| item.fetch("id") }
  end

  def test_stale_local_rate_falls_back_only_for_preview_to_usdt
    localization = Object.new
    def localization.locale_for(_value) = "uk_UA"
    def localization.resolve(language_code:)
      Struct.new(:currency).new("UAH")
    end
    def localization.present_client_price(amount_usdt:, currency:)
      raise ZeroXDA::Market::Localization::RateUnavailable, "rate stale" unless currency == "USDT"

      amount_usdt
    end

    document = get_document(localization: localization, query: "locale=uk_UA&preview_0x1=true")
    special = document.fetch("data").find { |item| item["id"] == "0x1_special_1m" }.fetch("attributes")
    assert_nil special.fetch("price")
    assert_equal "USDT", special.dig("preview_price", "currency")
    assert_equal "2.49", special.dig("preview_price", "amount")
  end

  private

  def get_document(localization:, query:)
    client = Rack::MockRequest.new(
      ZeroXDA::Market::Transport::JSONAPI.new(
        kernel: @kernel, token: "test-token", catalog: @catalog,
        pricing: @pricing, localization: localization
      )
    )
    response = client.get("/v1/products?#{query}", @headers)
    assert_equal 200, response.status
    JSON.parse(response.body)
  end
end
