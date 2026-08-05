# frozen_string_literal: true

require "bigdecimal"
require_relative "locale"
require_relative "../pricing/client_price_presentation_policy"

module ZeroXDA
  module Market
    module Localization
      # Currencies are catalog products with marketable: false. A currency's
      # exchange rate is its price: current_price_usdt is the real buy-side
      # rate — how many USDT we pay for one unit of the currency when
      # acquiring the product quantity. Rates are applied through the same
      # pricing flow as any product price.
      class Service
        BASE_CURRENCY = "USDT"
        DEFAULT_LOCALE = "en_US"
        LANGUAGE_LOCALES = {
          "en" => "en_US",
          "uk" => "uk_UA"
        }.freeze

        def initialize(catalog:, client_price_presentation: Pricing::ClientPricePresentationPolicy.new)
          @catalog = catalog
          @client_price_presentation = client_price_presentation
        end

        # Unsupported languages fall back to the default instead of failing:
        # the language code comes from Telegram clients and must never break
        # a flow.
        def resolve(language_code: nil, currency: nil)
          locale = locale_for(language_code)
          requested = currency.to_s.strip
          Locale.new(
            code: locale,
            currency: requested.empty? ? currency_for(locale) : requested.upcase
          )
        end

        def locale_for(language_code)
          base = language_code.to_s.downcase[/\A[a-z]{2}/]
          LANGUAGE_LOCALES.fetch(base, DEFAULT_LOCALE)
        end

        # The default currency for a locale, driven by currency product
        # metadata: {"locales": ["uk_UA", "uk_RU"]}.
        def currency_for(locale)
          normalized = locale.to_s
          product = currencies.find do |currency|
            Array(currency.metadata["locales"]).include?(normalized)
          end
          product&.currency_code || BASE_CURRENCY
        end

        # Exact FX conversion. This contract is used by domain and adapter code
        # that must not inherit client-facing commercial presentation rules.
        def convert(amount_usdt:, currency:)
          normalized = normalize_currency(currency)
          amount = decimal(amount_usdt, field: "amount_usdt")
          return amount if normalized == BASE_CURRENCY

          rate = rate_for(normalized)
          raise ArgumentError, "currency is not supported: #{normalized}" unless rate

          amount / rate
        end

        # Buyer-facing conversion applies smart commercial presentation only
        # after exact FX conversion. Keeping this as a separate port preserves
        # the existing conversion contract and prevents policy leakage.
        def present_client_price(amount_usdt:, currency:)
          normalized = normalize_currency(currency)
          exact = convert(amount_usdt: amount_usdt, currency: normalized)
          @client_price_presentation.present(amount: exact, currency: normalized)
        end

        # Converts a broker-denominated supply amount into the canonical
        # comparison unit used by allocation. The returned value is not a
        # buyer-facing price and is retained only as an internal cost input.
        def amount_usdt(amount:, currency:)
          normalized = normalize_currency(currency)
          value = decimal(amount, field: "amount")
          return value if normalized == BASE_CURRENCY

          rate = rate_for(normalized)
          raise ArgumentError, "currency is not supported: #{normalized}" unless rate

          (value * rate).round(8)
        end

        def supported_currency?(currency)
          normalized = normalize_currency(currency)
          normalized == BASE_CURRENCY || !rate_for(normalized).nil?
        end

        def currencies
          @catalog.currencies
        end

        private

        # A currency becomes usable once it has an applied price (= rate).
        def rate_for(code)
          currencies.find do |currency|
            currency.currency_code == code && currency.current_price_usdt
          end&.current_price_usdt
        end

        def normalize_currency(currency)
          value = currency.to_s.strip.upcase
          value.empty? ? BASE_CURRENCY : value
        end

        def decimal(value, field:)
          number = value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
          raise ArgumentError, "#{field} must be a positive number" unless number.finite? && number.positive?

          number
        rescue ArgumentError
          raise ArgumentError, "#{field} must be a positive number"
        end
      end
    end
  end
end
