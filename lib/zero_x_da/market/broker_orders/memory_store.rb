# frozen_string_literal: true

require "monitor"
require_relative "../core/contracts"

module ZeroXDA
  module Market
    module BrokerOrders
      class MemoryStore
        def initialize
          @monitor = Monitor.new
          @decisions = {}
        end

        def transaction(&block)
          @monitor.synchronize { block.call(self) }
        end

        def find(order_id)
          @monitor.synchronize { @decisions[order_id.to_s] }
        end

        def list_by_seller(seller_user_id)
          @monitor.synchronize do
            @decisions.values
                      .select { |decision| decision.seller_user_id == seller_user_id.to_s }
                      .sort_by { |decision| [decision.updated_at, decision.order_id] }
                      .reverse
          end
        end

        def insert(decision)
          raise Core::Conflict.new(
            "broker order decision already exists",
            code: "duplicate_broker_order_decision",
            details: { order_id: decision.order_id }
          ) if @decisions.key?(decision.order_id)

          @decisions[decision.order_id] = decision
        end

        def replace(decision, expected_version:)
          current = @decisions[decision.order_id] ||
                    raise(Core::NotFound.new("broker_order_decision", decision.order_id))
          unless current.version == expected_version
            raise Core::ConcurrencyConflict.new("broker_order_decision", decision.order_id)
          end

          @decisions[decision.order_id] = decision
        end
      end
    end
  end
end
