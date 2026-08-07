# frozen_string_literal: true

require "bigdecimal"

module ZeroXDA
  module Market
    module Pricing
      # Keeps a bounded amount of broker routing room above the best normalized
      # ask. The headroom is market-owned: another broker cannot push the buyer
      # price upward, while brokers close to the best ask can remain executable
      # and compete for the non-best routing tiers.
      class CompetitiveReferencePolicy
        BASIS_POINTS = BigDecimal("10000")
        DEFAULT_ROUTING_HEADROOM_BPS = 500

        attr_reader :routing_headroom_bps

        def initialize(routing_headroom_bps: DEFAULT_ROUTING_HEADROOM_BPS)
          @routing_headroom_bps = Integer(routing_headroom_bps)
          unless @routing_headroom_bps.between?(0, 9_999)
            raise ArgumentError, "routing headroom must be between 0 and 9999 basis points"
          end

          @routing_headroom_rate = BigDecimal(@routing_headroom_bps.to_s) / BASIS_POINTS
          freeze
        rescue ArgumentError, TypeError
          raise ArgumentError, "routing headroom must be between 0 and 9999 basis points"
        end

        def reference_supply_cost_usdt(cheapest_supply_cost_usdt:)
          cheapest = positive_decimal(cheapest_supply_cost_usdt)
          (cheapest * (1 + @routing_headroom_rate)).round(8, BigDecimal::ROUND_CEILING)
        end

        private

        def positive_decimal(value)
          number = value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
          raise ArgumentError unless number.finite? && number.positive?

          number
        rescue ArgumentError, TypeError
          raise ArgumentError, "cheapest supply cost must be a positive decimal"
        end
      end
    end
  end
end
