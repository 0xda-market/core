# frozen_string_literal: true

require_relative "../core/contracts"
require_relative "order"

module ZeroXDA
  module Market
    module IssuerOrders
      class MemoryStore
        def initialize
          @orders = {}
          @events = []
          @mutex = Mutex.new
        end

        # Returns [order, created]. A repeated idempotency key returns the
        # existing order unchanged and records no event.
        def create(order, event:)
          @mutex.synchronize do
            existing = @orders.values.find do |candidate|
              candidate.customer_user_id == order.customer_user_id && candidate.idempotency_key == order.idempotency_key
            end
            next [existing, false] if existing

            @orders[order.id] = order
            @events << event
            [order, true]
          end
        end

        def find(id)
          @mutex.synchronize { @orders[id.to_s] }
        end

        def find_by_idempotency_key(customer_user_id:, idempotency_key:)
          @mutex.synchronize do
            @orders.values.find do |order|
              order.customer_user_id == customer_user_id && order.idempotency_key == idempotency_key
            end
          end
        end

        def find_by_issuer_reference(issuer:, reference:)
          @mutex.synchronize do
            @orders.values.find { |order| order.issuer == issuer && order.issuer_reference == reference }
          end
        end

        def replace(order, expected_version:, event:)
          @mutex.synchronize do
            current = @orders[order.id]
            unless current && current.version == expected_version
              raise Core::ConcurrencyConflict.new("issuer_order", order.id)
            end
            if order.issuer_reference &&
               @orders.values.any? { |other| other.id != order.id && other.issuer == order.issuer && other.issuer_reference == order.issuer_reference }
              raise Core::Conflict.new("issuer reference is already used", code: "issuer_reference_conflict",
                                                                          details: { reference: order.issuer_reference })
            end

            @orders[order.id] = order
            @events << event
            order
          end
        end

        def list(issuer:, status:, limit:)
          @mutex.synchronize do
            @orders.values
                   .select { |order| order.issuer == issuer && order.status == status }
                   .sort_by { |order| [order.created_at, order.id] }
                   .first(limit)
          end
        end

        def events(order_id)
          @mutex.synchronize { @events.select { |event| event.order_id == order_id.to_s } }
        end
      end
    end
  end
end
