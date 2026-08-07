# frozen_string_literal: true

require "bigdecimal"
require_relative "locale"
require_relative "errors"
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
          "uk" => "uk_UA",
          "ru" => "ru_RU",
          "es" => "es_ES",
          "pt" => "pt_BR"
        }.freeze
        LOCALE_PATTERN = /\A([a-z]{2})[-_]([A-Za-z]{2})\z/

        def initialize(
          catalog:,
          client_price_presentation: Pricing::ClientPricePresentationPolicy.new,
          clock: -> { Time.now.utc },
          max_rate_age_seconds: nil
        )
          @catalog = catalog
          @client_price_presentation = client_price_presentation
          @clock = clock
          @max_rate_age_seconds = normalize_max_rate_age(max_rate_age_seconds)
        end

        # UI language and currency geography are independent. A language-only
        # code selects canonical copy; an explicit region is retained for
        # currency selection so ru-KZ never becomes a Russian-currency signal.
        def resolve(language_code: nil, currency: nil)
          locale = locale_for(language_code)
          requested = currency.to_s.strip
          Locale.new(
            code: locale,
            currency: requested.empty? ? currency_for_request(language_code, locale) : requested.upcase
          )
        end

        def locale_for(language_code)
          raw = language_code.to_s.strip
          match = LOCALE_PATTERN.match(raw)
          return canonical_regional_locale(match[1], match[2]) if match

          base = raw.downcase[/\A[a-z]{2}/]
          LANGUAGE_LOCALES.fetch(base, DEFAULT_LOCALE)
        end

        # The default currency for a locale is driven by currency product
        # metadata. Only explicit regional locales participate; language-only
        # ru/es/pt inputs remain currency-neutral because those languages span
        # multiple markets.
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
          raise RateUnavailable, "currency is not supported or its rate is stale: #{normalized}" unless rate

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
          raise RateUnavailable, "currency is not supported or its rate is stale: #{normalized}" unless rate

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

        def canonical_regional_locale(language, region)
          base = language.downcase
          territory = region.upcase
          return DEFAULT_LOCALE unless LANGUAGE_LOCALES.key?(base) || regional_skeleton_language?(base)

          "#{base}_#{territory}"
        end

        def regional_skeleton_language?(language)
          %w[de fr it pl cs hu].include?(language)
        end

        def currency_for_request(language_code, locale)
          raw = language_code.to_s.strip
          match = LOCALE_PATTERN.match(raw)
          return currency_for(locale) if match

          base = raw.downcase[/\A[a-z]{2}/]
          return BASE_CURRENCY if %w[ru es pt].include?(base)

          currency_for(locale)
        end

        # A currency becomes usable once it has an applied price (= rate). In
        # configured runtimes, provider-managed rates also have a hard TTL so a
        # long upstream outage cannot silently produce stale buyer prices.
        def rate_for(code)
          currencies.find do |currency|
            currency.currency_code == code && currency.current_price_usdt && fresh_rate?(currency)
          end&.current_price_usdt
        end

        def fresh_rate?(currency)
          return true if @max_rate_age_seconds.nil?
          return false unless currency.price_updated_at

          age = current_time - currency.price_updated_at
          age >= 0 && age <= @max_rate_age_seconds
        end

        def normalize_max_rate_age(value)
          return nil if value.nil?

          seconds = Integer(value)
          raise ArgumentError unless seconds.positive?

          seconds
        rescue ArgumentError, TypeError
          raise ArgumentError, "max_rate_age_seconds must be a positive integer"
        end

        def current_time
          value = @clock.call
          raise ArgumentError, "clock must return a Time" unless value.is_a?(Time)

          value.getutc
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
