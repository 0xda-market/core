# frozen_string_literal: true

require_relative "contracts"

module ZeroXDA
  module Market
    module Settlement
      module KernelIntegration
        def initialize(settlement: nil, **options)
          @settlement_provider = settlement && Core::Contracts.validate_settlement_provider!(settlement)
          super(**options)
        end

        def settlement_cost(quote)
          return Core::Contracts::CostResult.new(variable_fee_bps: 0, fixed_cost_usdt: 0) unless @settlement_provider

          result = @settlement_provider.cost(quote: quote)
          return result if result.is_a?(Core::Contracts::CostResult)

          raise Core::ProviderContractError.new("settlement cost returned an invalid result")
        rescue Core::ProviderFailure
          raise
        rescue StandardError => error
          raise Core::ProviderFailure.new(
            "settlement cost raised an unexpected error",
            code: "unhandled_settlement_error",
            retryable: false,
            details: { exception: error.class.name }
          )
        end

        def charge_settlement(order_id)
          return nil unless @settlement_provider

          order = find_order(order_id)
          result = @settlement_provider.charge(
            order: order,
            idempotency_key: "orders/#{order.id}/settlement"
          )
          unless result.is_a?(Core::Contracts::SettlementResult) || result.is_a?(Core::Contracts::PendingSettlement)
            raise Core::ProviderContractError.new("settlement charge returned an invalid result")
          end
          result
        end

        def verify_settlement(settlement)
          return nil unless @settlement_provider

          result = @settlement_provider.verify(settlement: settlement)
          unless result.is_a?(Core::Contracts::SettlementResult)
            raise Core::Conflict.new(
              "settlement is not complete",
              code: "payment_required",
              details: { settlement_id: settlement.id }
            )
          end
          result
        end

        private

        def start_execution(id)
          if @settlement_provider
            order = find_order(id)
            if order.payment
              settlement = @settlement_provider.respond_to?(:find_by_order) && @settlement_provider.find_by_order(order.id)
              if settlement
                verified = @settlement_provider.verify(settlement: settlement)
                unless verified.is_a?(Core::Contracts::SettlementResult)
                  raise Core::Conflict.new(
                    "settlement is required before fulfillment",
                    code: "payment_required",
                    details: { order_id: order.id }
                  )
                end
              end
            end
          end
          super
        end
      end

      module MarketplaceIntegration
        def quote(**arguments)
          result = super
          @kernel.settlement_cost(result.quote)
          result
        end

        def accept(customer_user_id:, quote_id:)
          result = super
          @kernel.charge_settlement(result.order.id)
          result
        rescue StandardError
          begin
            release_quote(customer_user_id: customer_user_id, quote_id: quote_id) if result
          rescue StandardError
            nil
          end
          raise
        end

        def confirm_payment(order_id:, reference:, data: {}, settlement: nil)
          if settlement
            @kernel.verify_settlement(settlement)
          elsif @settlement_provider
            current = @settlement_provider.find_by_order(order_id)
            @kernel.verify_settlement(current) if current
          end
          super(order_id: order_id, reference: reference, data: data)
        end

        def initialize(settlement_provider: nil, **options)
          @settlement_provider = settlement_provider
          super(**options)
        end
      end
    end
  end
end

ZeroXDA::Market::Core::Kernel.prepend(ZeroXDA::Market::Settlement::KernelIntegration)
ZeroXDA::Market::Marketplace::Service.prepend(ZeroXDA::Market::Settlement::MarketplaceIntegration)
