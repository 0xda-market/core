# frozen_string_literal: true

require "bigdecimal"

module ZeroXDA
  module Market
    module Pricing
      class ProfitabilityPolicy
        PRICE_SCALE = 6
        BASIS_POINTS = BigDecimal("10000")

        DEFAULT_MINIMUM_MARGIN_BPS = 100
        DEFAULT_SUPPLY_BUFFER_BPS = 100
        DEFAULT_VARIABLE_FEE_BPS = 0
        DEFAULT_FIXED_COST_USDT = BigDecimal("0")

        attr_reader :minimum_margin_bps,
                    :supply_buffer_bps,
                    :variable_fee_bps,
                    :fixed_cost_usdt

        def initialize(
          minimum_margin_bps: DEFAULT_MINIMUM_MARGIN_BPS,
          supply_buffer_bps: DEFAULT_SUPPLY_BUFFER_BPS,
          variable_fee_bps: DEFAULT_VARIABLE_FEE_BPS,
          fixed_cost_usdt: DEFAULT_FIXED_COST_USDT
        )
          @minimum_margin_bps = basis_points(
            minimum_margin_bps,
            field: "minimum margin",
            positive: true
          )
          @supply_buffer_bps = basis_points(
            supply_buffer_bps,
            field: "supply buffer"
          )
          @variable_fee_bps = basis_points(
            variable_fee_bps,
            field: "variable fee"
          )
          @fixed_cost_usdt = non_negative_decimal(fixed_cost_usdt, field: "fixed cost")

          if @minimum_margin_bps + @variable_fee_bps >= BASIS_POINTS.to_i
            raise ArgumentError, "minimum margin and variable fee must total less than 10000 bps"
          end

          @minimum_margin_rate = BigDecimal(@minimum_margin_bps.to_s) / BASIS_POINTS
          @supply_buffer_rate = BigDecimal(@supply_buffer_bps.to_s) / BASIS_POINTS
          @variable_fee_rate = BigDecimal(@variable_fee_bps.to_s) / BASIS_POINTS

          freeze
        end

        def minimum_client_total_usdt(supply_unit_cost_usdt:, quantity:)
          supply_unit_cost = positive_decimal(supply_unit_cost_usdt, field: "supply unit cost")
          requested_quantity = positive_decimal(quantity, field: "quantity")
          buffered_supply_cost = supply_unit_cost * requested_quantity * (1 + supply_buffer_rate)
          denominator = 1 - variable_fee_rate - minimum_margin_rate

          round_up((buffered_supply_cost + fixed_cost_usdt) / denominator)
        end

        def minimum_client_unit_price_usdt(supply_unit_cost_usdt:, quantity:)
          requested_quantity = positive_decimal(quantity, field: "quantity")
          minimum_total = minimum_client_total_usdt(
            supply_unit_cost_usdt: supply_unit_cost_usdt,
            quantity: requested_quantity
          )

          round_up(minimum_total / requested_quantity)
        end

        def profitable?(client_total_usdt:, supply_unit_cost_usdt:, quantity:)
          revenue = positive_decimal(client_total_usdt, field: "client total")
          supply_unit_cost = positive_decimal(supply_unit_cost_usdt, field: "supply unit cost")
          requested_quantity = positive_decimal(quantity, field: "quantity")
          buffered_supply_cost = supply_unit_cost * requested_quantity * (1 + supply_buffer_rate)
          variable_fee = revenue * variable_fee_rate
          profit = revenue - buffered_supply_cost - fixed_cost_usdt - variable_fee

          profit.positive? && (profit / revenue) >= minimum_margin_rate
        end

        # Inverts the profitability contract for broker guidance and listing
        # eligibility. The result is rounded down to the broker price storage
        # scale, so displaying it can never suggest an insolvent ask.
        def maximum_supply_unit_cost_usdt(client_unit_price_usdt:, quantity:)
          client_unit_price = positive_decimal(client_unit_price_usdt, field: "client unit price")
          requested_quantity = positive_decimal(quantity, field: "quantity")
          revenue = client_unit_price * requested_quantity
          available_for_buffered_supply =
            revenue * (1 - variable_fee_rate - minimum_margin_rate) - fixed_cost_usdt
          return nil unless available_for_buffered_supply.positive?

          maximum = available_for_buffered_supply /
                    (requested_quantity * (1 + supply_buffer_rate))
          maximum.round(8, BigDecimal::ROUND_FLOOR)
        end

        private

        def minimum_margin_rate
          @minimum_margin_rate
        end

        def supply_buffer_rate
          @supply_buffer_rate
        end

        def variable_fee_rate
          @variable_fee_rate
        end

        def basis_points(value, field:, positive: false)
          number = Integer(value)
          minimum = positive ? 1 : 0
          unless number.between?(minimum, 9_999)
            qualifier = positive ? "between 1 and 9999" : "between 0 and 9999"
            raise ArgumentError, "#{field} must be #{qualifier} basis points"
          end

          number
        rescue ArgumentError, TypeError
          qualifier = positive ? "between 1 and 9999" : "between 0 and 9999"
          raise ArgumentError, "#{field} must be #{qualifier} basis points"
        end

        def positive_decimal(value, field:)
          number = decimal(value, field: field)
          raise ArgumentError, "#{field} must be positive" unless number.positive?

          number
        end

        def non_negative_decimal(value, field:)
          number = decimal(value, field: field)
          raise ArgumentError, "#{field} must not be negative" if number.negative?

          number
        end

        def decimal(value, field:)
          number = value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
          raise ArgumentError, "#{field} must be finite" unless number.finite?

          number
        rescue ArgumentError, TypeError
          raise ArgumentError, "#{field} must be a finite decimal"
        end

        def round_up(value)
          value.round(PRICE_SCALE, BigDecimal::ROUND_CEILING)
        end
      end
    end
  end
end
