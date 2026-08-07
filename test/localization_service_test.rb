# frozen_string_literal: true

require "minitest/autorun"
require "bigdecimal"
require "time"
require_relative "../lib/zero_x_da/market/catalog/memory_store"
require_relative "../lib/zero_x_da/market/catalog/service"
require_relative "../lib/zero_x_da/market/localization/service"

module ZeroXDA
  module Market
    module Localization
      class ServiceTest < Minitest::Test
        NOW = Time.utc(2026, 7, 15, 8, 0, 0)

        def setup
          store = Catalog::MemoryStore.new(
            products: [
              product("premium_3m", position: 1),
              currency("usdt", "USDT", price: "1", position: 100),
              currency("usd", "USD", price: nil, position: 101, locales: %w[en_US]),
              currency("uah", "UAH", price: "41.5", position: 102, locales: %w[uk_UA]),
              currency("rub", "RUB", price: "0.012", position: 103, locales: %w[ru_RU]),
              currency("eur", "EUR", price: "1.1", position: 104, locales: %w[de_DE fr_FR it_IT es_ES])
            ]
          )
          catalog = Catalog::Service.new(store: store)
          @catalog = catalog
          @service = Service.new(catalog: catalog)
        end

        def test_locale_for_maps_primary_languages_and_preserves_supported_regions
          assert_equal "en_US", @service.locale_for("en")
          assert_equal "uk_UA", @service.locale_for("uk-UA")
          assert_equal "ru_RU", @service.locale_for("ru")
          assert_equal "ru_KZ", @service.locale_for("ru-KZ")
          assert_equal "es_MX", @service.locale_for("es-MX")
          assert_equal "pt_BR", @service.locale_for("pt-BR")
          assert_equal "de_DE", @service.locale_for("de-DE")
          assert_equal Service::DEFAULT_LOCALE, @service.locale_for("ja-JP")
          assert_equal Service::DEFAULT_LOCALE, @service.locale_for(nil)
        end

        def test_catalog_excludes_currencies_from_the_sellable_list
          assert_equal %w[premium_3m], @catalog.products.map(&:sku)
          assert_equal %w[usdt usd uah rub eur], @catalog.currencies.map(&:sku)
          assert @catalog.currencies.all?(&:currency?)
        end

        def test_convert_returns_base_amount_unchanged
          amount = @service.convert(amount_usdt: "12.50", currency: "USDT")
          assert_equal BigDecimal("12.5"), amount
        end

        def test_convert_uses_the_currency_product_price_as_the_rate
          amount = @service.convert(amount_usdt: "83.0", currency: "UAH")
          assert_equal BigDecimal("2"), amount
        end

        def test_a_currency_without_an_applied_price_is_not_supported
          refute @service.supported_currency?("USD")
          assert_raises(ArgumentError) do
            @service.convert(amount_usdt: "10", currency: "USD")
          end
        end

        def test_rejects_a_provider_rate_after_its_runtime_ttl
          clock = MutableClock.new(NOW)
          store = Catalog::MemoryStore.new(
            products: [
              currency(
                "uah",
                "UAH",
                price: "0.024",
                price_updated_at: NOW,
                position: 102
              )
            ]
          )
          service = Service.new(
            catalog: Catalog::Service.new(store: store),
            clock: clock,
            max_rate_age_seconds: 3600
          )

          assert service.supported_currency?("UAH")
          clock.advance(3601)
          refute service.supported_currency?("UAH")
          assert_raises(ArgumentError) do
            service.convert(amount_usdt: "10", currency: "UAH")
          end
        end

        def test_unknown_currency_is_rejected
          assert_raises(ArgumentError) do
            @service.convert(amount_usdt: "10", currency: "JPY")
          end
          refute @service.supported_currency?("JPY")
        end

        def test_currency_for_resolves_only_explicit_regional_defaults
          assert_equal "UAH", @service.currency_for("uk_UA")
          assert_equal "RUB", @service.currency_for("ru_RU")
          assert_equal "EUR", @service.currency_for("es_ES")
          assert_equal "USD", @service.currency_for("en_US")
          assert_equal Service::BASE_CURRENCY, @service.currency_for("ru_KZ")
          assert_equal Service::BASE_CURRENCY, @service.currency_for("es_MX")
        end

        def test_resolve_keeps_language_and_currency_geography_independent
          ukrainian = @service.resolve(language_code: "uk")
          assert_equal "uk_UA", ukrainian.code
          assert_equal "UAH", ukrainian.currency

          kazakh_russian = @service.resolve(language_code: "ru-KZ")
          assert_equal "ru_KZ", kazakh_russian.code
          assert_equal "USDT", kazakh_russian.currency

          latin_american_spanish = @service.resolve(language_code: "es-MX")
          assert_equal "es_MX", latin_american_spanish.code
          assert_equal "USDT", latin_american_spanish.currency

          european_spanish = @service.resolve(language_code: "es-ES")
          assert_equal "es_ES", european_spanish.code
          assert_equal "EUR", european_spanish.currency

          language_only_russian = @service.resolve(language_code: "ru")
          assert_equal "ru_RU", language_only_russian.code
          assert_equal "USDT", language_only_russian.currency

          explicit = @service.resolve(language_code: "ru-KZ", currency: "rub")
          assert_equal "RUB", explicit.currency
        end

        private

        def product(sku, position:)
          Catalog::Product.new(
            sku: sku,
            short_name: sku,
            name: sku,
            button_label: sku,
            position: position,
            created_at: NOW
          )
        end

        def currency(sku, code, price:, position:, locales: [], price_updated_at: nil)
          Catalog::Product.new(
            sku: sku,
            short_name: code,
            name: code,
            button_label: code,
            position: position,
            marketable: false,
            metadata: {
              "family" => "currency",
              "code" => code,
              "locales" => locales
            },
            current_price_usdt: price,
            price_updated_at: price_updated_at,
            created_at: NOW
          )
        end
      end
    end
  end
end
