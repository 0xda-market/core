# frozen_string_literal: true

require_relative "test_helper"
require "zero_x_da/market/fx/refresh_service"
require "zero_x_da/market/pricing/memory_store"
require "zero_x_da/market/pricing/service"

class FXRefreshServiceTest < Minitest::Test
  FX = ZeroXDA::Market::FX
  Pricing = ZeroXDA::Market::Pricing
  Currency = Struct.new(:sku, :currency_code, keyword_init: true)

  class Catalog
    def initialize
      @currencies = [
        Currency.new(sku: "usdt", currency_code: "USDT"),
        Currency.new(sku: "usd", currency_code: "USD"),
        Currency.new(sku: "uah", currency_code: "UAH")
      ]
    end

    def currencies
      @currencies
    end

    def find_product(sku, locale: "en_US")
      @currencies.find { |currency| currency.sku == sku.to_s } ||
        raise(ZeroXDA::Market::Core::NotFound.new("product", sku))
    end
  end

  class Provider
    attr_reader :requested

    def initialize(observed_at:)
      @observed_at = observed_at
    end

    def fetch(currencies:)
      @requested = currencies
      FX::RateSnapshot.new(
        provider: "test-provider",
        rates: { "USD" => "1.001", "UAH" => "0.0224" },
        observed_at: @observed_at
      )
    end
  end

  def test_appends_one_atomic_provider_snapshot_without_rewriting_usdt
    now = Time.utc(2026, 8, 6, 8, 0, 0)
    catalog = Catalog.new
    pricing = Pricing::Service.new(
      store: Pricing::MemoryStore.new,
      catalog: catalog,
      clock: -> { now }
    )
    provider = Provider.new(observed_at: now)
    service = FX::RefreshService.new(
      provider: provider,
      catalog: catalog,
      pricing: pricing
    )

    result = service.refresh

    assert_equal %w[USD UAH], provider.requested
    assert_equal %w[usd uah], result.prices.map(&:sku)
    assert result.prices.all? { |price| price.source == "fx:test-provider" }
    assert_equal BigDecimal("1.001"), pricing.current_price("usd").amount_usdt
    assert_equal BigDecimal("0.0224"), pricing.current_price("uah").amount_usdt
    assert_nil pricing.current_price("usdt")
  end

  def test_invalid_snapshot_does_not_append_a_partial_rate_set
    now = Time.utc(2026, 8, 6, 8, 0, 0)
    catalog = Catalog.new
    pricing = Pricing::Service.new(
      store: Pricing::MemoryStore.new,
      catalog: catalog,
      clock: -> { now }
    )
    provider = Object.new
    provider.define_singleton_method(:fetch) do |currencies:|
      FX::RateSnapshot.new(
        provider: "test-provider",
        rates: { "USD" => "1" },
        observed_at: now
      )
    end
    service = FX::RefreshService.new(provider: provider, catalog: catalog, pricing: pricing)

    assert_raises(KeyError) { service.refresh }
    assert_empty pricing.current_prices
  end
end
