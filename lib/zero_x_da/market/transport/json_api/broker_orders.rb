# frozen_string_literal: true

require_relative "endpoint_handler"
require_relative "router"

module ZeroXDA
  module Market
    module Transport
      class JSONAPI
        module BrokerOrderEndpoints
          def initialize(broker_orders: nil, **options)
            @broker_orders = broker_orders
            super(**options)
          end

          def available?(endpoint)
            return !@broker_orders.nil? if endpoint == :broker_orders
            super
          end

          def broker_orders(request)
            entries = @broker_orders.list(actor_user_id: request.params.fetch("actor_user_id"))
            json_response(200, { "data" => entries.map { |entry| present_broker_order(entry) },
                                 "meta" => { "count" => entries.length } })
          end

          def accept_broker_order(request, id:)
            body = @request_parser.request_document(request)
            resource_response(200, present_broker_order(@broker_orders.accept(
              actor_user_id: body.fetch("actor_user_id"), order_id: id,
              expected_version: body.fetch("version")
            )))
          end

          def complete_broker_order(request, id:)
            body = @request_parser.request_document(request)
            resource_response(200, present_broker_order(@broker_orders.complete(
              actor_user_id: body.fetch("actor_user_id"), order_id: id,
              expected_version: body.fetch("version"), reference: body["reference"],
              data: body.fetch("data", {})
            )))
          end

          def acknowledge_broker_order_notification(request, id:, event:)
            body = @request_parser.request_document(request)
            resource_response(200, present_broker_order(@broker_orders.acknowledge_notification(
              actor_user_id: body.fetch("actor_user_id"), order_id: id, event: event
            )))
          end

          private

          def present_broker_order(entry)
            decision = entry.decision
            product = entry.order.payload.fetch("product", {})
            resource = {
              "type" => "broker_order", "id" => decision.order_id,
              "attributes" => {
                "status" => decision.status, "order_status" => entry.order.status,
                "payment_status" => entry.order.payment&.fetch("status", nil) || "not_required",
                "sku" => entry.listing.sku, "product_name" => product["name"],
                "quantity" => decimal_string(entry.reservation.quantity),
                "client_total_price_usdt" => product["total_price_usdt"],
                "currency" => product["currency"] || "USDT",
                "accepted_at" => timestamp(decision.accepted_at),
                "completed_at" => timestamp(decision.completed_at),
                "created_at" => timestamp(decision.created_at),
                "updated_at" => timestamp(decision.updated_at), "version" => decision.version
              }
            }
            event = decision.pending_notification_event
            resource["meta"] = {
              "notification_event" => event,
              "notification_recipient_user_id" => event && entry.reservation.customer_user_id
            }.compact
            resource
          end
        end

        module BrokerOrderRoutes
          private

          def resolve(request)
            method = request.request_method
            path = request.path_info
            return route(:broker_orders) if method == "GET" && path == "/v1/broker/orders" && available?(:broker_orders)

            accept_match = path.match(%r{\A/v1/broker/orders/([^/]+)/accept\z})
            return route(:accept_broker_order, id: accept_match[1]) if method == "POST" && accept_match && available?(:broker_orders)

            complete_match = path.match(%r{\A/v1/broker/orders/([^/]+)/complete\z})
            return route(:complete_broker_order, id: complete_match[1]) if method == "POST" && complete_match && available?(:broker_orders)

            notification_match = path.match(%r{\A/v1/broker/orders/([^/]+)/notifications/([^/]+)/ack\z})
            if method == "POST" && notification_match && available?(:broker_orders)
              return route(:acknowledge_broker_order_notification,
                           id: notification_match[1], event: notification_match[2])
            end
            super
          end
        end

        EndpointHandler.prepend(BrokerOrderEndpoints)
        Router.prepend(BrokerOrderRoutes)
      end
    end
  end
end
