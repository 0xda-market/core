# frozen_string_literal: true

require "bigdecimal"

module ZeroXDA
  module Market
    module Pricing
      # Converts an exact localized amount into a market-facing amount with a
      # predictable, currency-aware commercial shape. This policy never rounds
      # down, so presentation cannot reduce the profitability-protected price.
      class ClientPricePresentationPolicy
        DEFAULT_RULE = { mode: :minor_unit, step: "0.01" }.freeze
        RULES = {
          "USD" => { mode: :step, step: "0.05" },
          "EUR" => { mode: :step, step: "0.05" },
          "GBP" => { mode: :step, step: "0.05" },
          "CHF" => { mode: :step, step: "0.05" },
          "PLN" => { mode: :ending, endings: ["9", "19", "49", "99"], cycle: "100" },
          "CZK" => { mode: :ending, endings: ["9", "19", "49", "99"], cycle: "100" },
          "UAH" => { mode: :step, step: "50" },
          "RUB" => { mode: :step, step: "50" },
          "HUF" => { mode: :ending, endings: ["9", "49", "99"], cycle: "100" }
        }.freeze

        def present(amount:, currency:)
          value = positive_decimal(amount)
          rule = RULES.fetch(currency.to_s.upcase, DEFAULT_RULE)

          case rule.fetch(:mode)
          when :step, :minor_unit
            ceil_to_step(value, decimal(rule.fetch(:step)))
          when :ending
            ceil_to_ending(value, rule)
          else
            raise ArgumentError, "unsupported client price presentation mode"
          end
        end

        private

        def ceil_to_step(value, step)
          (value / step).ceil * step
        end

        def ceil_to_ending(value, rule)
          cycle = decimal(rule.fetch(:cycle))
          cycle_base = (value / cycle).floor * cycle
          endings = rule.fetch(:endings).map { |ending| decimal(ending) }
          candidate = endings.map { |ending| cycle_base + ending }
                             .find { |amount| amount >= value }
          candidate || cycle_base + cycle + endings.first
        end

        def positive_decimal(value)
          number = decimal(value)
          raise ArgumentError, "amount must be a positive finite decimal" unless number.finite? && number.positive?

          number
        rescue ArgumentError, TypeError
          raise ArgumentError, "amount must be a positive finite decimal"
        end

        def decimal(value)
          value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
        end
      end
    end
  end
end
