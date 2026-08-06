# frozen_string_literal: true

require "bigdecimal"
require_relative "../core/records"

module ZeroXDA
  module Market
    module FX
      # Provider-neutral, all-or-nothing set of USDT buy-side exchange rates.
      class RateSnapshot
        CURRENCY_PATTERN = /\A[A-Z][A-Z0-9]{2,9}\z/
        PROVIDER_PATTERN = /\A[a-z0-9][a-z0-9._-]{0,63}\z/

        attr_reader :provider, :rates, :observed_at

        def initialize(provider:, rates:, observed_at:)
          @provider = provider.to_s
          raise ArgumentError, "FX provider key is invalid" unless PROVIDER_PATTERN.match?(@provider)
          raise ArgumentError, "FX rates must be a non-empty object" unless rates.respond_to?(:to_h) && !rates.empty?

          @rates = rates.to_h.each_with_object({}) do |(currency, value), normalized|
            code = currency.to_s.strip.upcase
            raise ArgumentError, "currency code is invalid: #{currency}" unless CURRENCY_PATTERN.match?(code)

            normalized[code] = positive_decimal(value, currency: code)
          end.freeze
          @observed_at = Core::RecordSupport.time(observed_at, field: "observed_at")
          freeze
        end

        def fetch(currency)
          @rates.fetch(currency.to_s.strip.upcase)
        end

        private

        def positive_decimal(value, currency:)
          number = value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
          raise ArgumentError unless number.finite? && number.positive?

          number
        rescue ArgumentError, TypeError
          raise ArgumentError, "FX rate must be a positive finite decimal: #{currency}"
        end
      end
    end
  end
end
