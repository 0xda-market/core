# frozen_string_literal: true

require "bigdecimal"

module ZeroXDA
  module Market
    module Pricing
      # Prevents a single transient or mistyped supply ask from ratcheting an
      # established buyer price upward. Small increases remain automatic. Large
      # increases require corroboration from at least two distinct brokers whose
      # normalized asks remain inside a bounded spread around the best ask.
      #
      # Corroborating asks never become the pricing anchor; the cheapest valid
      # ask remains authoritative for CompetitiveReferencePolicy.
      class AutomaticPriceIncreasePolicy
        BASIS_POINTS = BigDecimal("10000")
        DEFAULT_MAX_UNCORROBORATED_INCREASE_BPS = 1_500
        DEFAULT_CORROBORATION_SPREAD_BPS = 1_000

        attr_reader :max_uncorroborated_increase_bps, :corroboration_spread_bps

        def initialize(
          max_uncorroborated_increase_bps: DEFAULT_MAX_UNCORROBORATED_INCREASE_BPS,
          corroboration_spread_bps: DEFAULT_CORROBORATION_SPREAD_BPS
        )
          @max_uncorroborated_increase_bps = basis_points(
            max_uncorroborated_increase_bps,
            field: "max uncorroborated increase"
          )
          @corroboration_spread_bps = basis_points(
            corroboration_spread_bps,
            field: "corroboration spread"
          )
          @max_uncorroborated_increase_rate =
            BigDecimal(@max_uncorroborated_increase_bps.to_s) / BASIS_POINTS
          @corroboration_spread_rate = BigDecimal(@corroboration_spread_bps.to_s) / BASIS_POINTS
          freeze
        end

        def allow_raise?(current_price_usdt:, required_price_usdt:, supply_costs_by_seller:)
          return true if current_price_usdt.nil?

          current = positive_decimal(current_price_usdt, field: "current price")
          required = positive_decimal(required_price_usdt, field: "required price")
          return true if required <= current

          uncorroborated_ceiling = current * (1 + @max_uncorroborated_increase_rate)
          return true if required <= uncorroborated_ceiling

          corroborated?(supply_costs_by_seller)
        end

        private

        def corroborated?(supply_costs_by_seller)
          normalized = Hash(supply_costs_by_seller).map do |seller_user_id, cost|
            [seller_user_id.to_s, positive_decimal(cost, field: "supply cost")]
          end
          return false if normalized.map(&:first).uniq.length < 2

          best = normalized.map(&:last).min
          ceiling = best * (1 + @corroboration_spread_rate)
          normalized.count { |(_, cost)| cost <= ceiling } >= 2
        rescue TypeError
          raise ArgumentError, "supply costs by seller must be a mapping"
        end

        def basis_points(value, field:)
          number = Integer(value)
          raise ArgumentError unless number.between?(0, 9_999)

          number
        rescue ArgumentError, TypeError
          raise ArgumentError, "#{field} must be between 0 and 9999 basis points"
        end

        def positive_decimal(value, field:)
          number = value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
          raise ArgumentError unless number.finite? && number.positive?

          number
        rescue ArgumentError, TypeError
          raise ArgumentError, "#{field} must be a positive decimal"
        end
      end
    end
  end
end
