# frozen_string_literal: true

require "bigdecimal"
require_relative "client_price_rounding_rules"

module ZeroXDA
  module Market
    module Pricing
      # Orchestrates client price presentation without owning currency-specific
      # rounding algorithms. Rules are supplied through a registry, keeping the
      # policy open for extension and stable for existing callers.
      class ClientPricePresentationPolicy
        def initialize(registry: ClientPriceRounding::Defaults.registry)
          @registry = registry
        end

        def present(amount:, currency:)
          value = positive_decimal(amount)
          presented = @registry.rule_for(currency).apply(value)
          unless presented.is_a?(BigDecimal) && presented.finite? && presented >= value
            raise ArgumentError, "client price rounding rule must return a finite amount without rounding down"
          end

          presented
        end

        private

        def positive_decimal(value)
          number = value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
          raise ArgumentError unless number.finite? && number.positive?

          number
        rescue ArgumentError, TypeError
          raise ArgumentError, "amount must be a positive finite decimal"
        end
      end
    end
  end
end
