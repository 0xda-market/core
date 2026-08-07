# frozen_string_literal: true

require "bigdecimal"
require_relative "../core/contracts"

module ZeroXDA
  module Market
    module Core
      module Contracts
        class CostResult
          attr_reader :variable_fee_bps, :fixed_cost_usdt

          def initialize(variable_fee_bps:, fixed_cost_usdt:)
            @variable_fee_bps = Integer(variable_fee_bps)
            unless @variable_fee_bps.between?(0, 9_999)
              raise ArgumentError, "variable_fee_bps must be between 0 and 9999"
            end

            @fixed_cost_usdt = BigDecimal(fixed_cost_usdt.to_s)
            unless @fixed_cost_usdt.finite? && !@fixed_cost_usdt.negative?
              raise ArgumentError, "fixed_cost_usdt must be a finite non-negative decimal"
            end
            freeze
          rescue TypeError
            raise ArgumentError, "settlement cost is invalid"
          end
        end

        class SettlementResult
          attr_reader :settlement, :reference, :data

          def initialize(settlement:, reference: nil, data: {})
            @settlement = settlement
            @reference = reference && RecordSupport.identifier(reference.to_s, field: "settlement reference")
            @data = RecordSupport.document(data, field: "settlement data")
            freeze
          end
        end

        class PendingSettlement
          attr_reader :settlement, :reference, :data

          def initialize(settlement:, reference:, data: {})
            @settlement = settlement
            @reference = RecordSupport.identifier(reference.to_s, field: "settlement reference")
            @data = RecordSupport.document(data, field: "settlement data")
            freeze
          end
        end

        module_function

        def validate_settlement_provider!(provider)
          required = %i[key cost charge verify]
          missing = required.reject { |method_name| provider.respond_to?(method_name) }
          return provider if missing.empty?

          raise ProviderContractError.new(
            "settlement provider does not implement the required contract",
            details: { missing_methods: missing.map(&:to_s) }
          )
        end
      end
    end
  end
end
