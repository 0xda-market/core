# frozen_string_literal: true
# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT

require "bigdecimal"

module ZeroXDA
  module Market
    module Pricing
      # Computes a term discount before choosing the nearest allowed
      # promotional USDT ending. This is a *sale price decision*, not
      # the upward-only localized FX presentation policy.
      class TermPromotionPolicy
        CENT = BigDecimal("0.01")
        BASIS = BigDecimal("10000")

        def price(monthly_usdt:, months:, discount_bps:, endings_cents:)
          monthly = decimal(monthly_usdt)
          months = Integer(months)
          discount = Integer(discount_bps)
          endings = Array(endings_cents).map { |value| Integer(value) }.uniq.sort

          raise ArgumentError, "monthly_usdt must be positive" unless monthly.finite? && monthly.positive?
          raise ArgumentError, "months must be between 1 and 120" unless (1..120).cover?(months)
          raise ArgumentError, "discount_bps must be between 0 and 9999" unless (0..9999).cover?(discount)
          if endings.empty? || endings.any? { |ending| !(0..99).cover?(ending) }
            raise ArgumentError, "endings_cents must contain USDT cent endings in 0..99"
          end

          target = monthly * months * (BASIS - discount) / BASIS
          floor_dollars = target.floor
          candidates = ((floor_dollars - 1)..(floor_dollars + 1)).flat_map do |dollars|
            endings.filter_map do |cents|
              price = BigDecimal(dollars.to_s) + BigDecimal(cents.to_s) * CENT
              price if price.positive?
            end
          end
          # Equal distance prefers the cheaper price. Neither the pricing
          # floor nor the advertised discount is silently changed by FX code.
          candidates.min_by { |candidate| [(candidate - target).abs, candidate] }
        rescue ArgumentError, TypeError
          raise ArgumentError, "invalid promotional term pricing inputs"
        end

        private

        def decimal(value)
          value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
        end
      end
    end
  end
end
