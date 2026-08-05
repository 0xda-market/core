# frozen_string_literal: true

require "bigdecimal"

module ZeroXDA
  module Market
    module Pricing
      module ClientPriceRounding
        module DecimalValue
          private

          def decimal(value)
            value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
          rescue ArgumentError, TypeError
            raise ArgumentError, "rounding values must be finite decimals"
          end
        end

        class StepRule
          include DecimalValue

          def initialize(step:)
            @step = decimal(step)
            raise ArgumentError, "rounding step must be positive" unless @step.finite? && @step.positive?
            freeze
          end

          def apply(amount)
            (amount / @step).ceil * @step
          end
        end

        class EndingRule
          include DecimalValue

          def initialize(endings:, cycle:)
            @cycle = decimal(cycle)
            @endings = endings.map { |ending| decimal(ending) }.sort.freeze
            unless @cycle.finite? && @cycle.positive? && !@endings.empty? &&
                   @endings.all? { |ending| ending.finite? && ending >= 0 && ending < @cycle }
              raise ArgumentError, "commercial endings must fit a positive cycle"
            end
            freeze
          end

          def apply(amount)
            cycle_base = (amount / @cycle).floor * @cycle
            candidate = @endings.lazy.map { |ending| cycle_base + ending }
                                .find { |value| value >= amount }
            candidate || cycle_base + @cycle + @endings.first
          end
        end

        class Registry
          def initialize(rules:, default_rule:)
            @rules = rules.transform_keys { |currency| currency.to_s.upcase }.freeze
            @default_rule = default_rule
            freeze
          end

          def rule_for(currency)
            @rules.fetch(currency.to_s.upcase, @default_rule)
          end
        end

        module Defaults
          module_function

          def registry
            minor_unit = StepRule.new(step: "0.01")
            five_minor_units = StepRule.new(step: "0.05")
            fifty_units = StepRule.new(step: "50")
            common_endings = EndingRule.new(endings: %w[9 19 49 99], cycle: "100")
            huf_endings = EndingRule.new(endings: %w[9 49 99], cycle: "100")

            Registry.new(
              default_rule: minor_unit,
              rules: {
                "USD" => five_minor_units,
                "EUR" => five_minor_units,
                "GBP" => five_minor_units,
                "CHF" => five_minor_units,
                "PLN" => common_endings,
                "CZK" => common_endings,
                "UAH" => fifty_units,
                "RUB" => fifty_units,
                "HUF" => huf_endings
              }
            )
          end
        end
      end
    end
  end
end
