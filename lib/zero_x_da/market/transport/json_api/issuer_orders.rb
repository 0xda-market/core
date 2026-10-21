# frozen_string_literal: true

require_relative "../issuer_order_presenter"

module ZeroXDA
  module Market
    module Transport
      class JSONAPI
        # Customer side of issuer orders. The actor is always the customer;
        # another customer's order is reported as not found.
        module IssuerOrderEndpoints
          include IssuerOrderPresenter

          def initialize(issuer_orders: nil, **options)
            @issuer_orders = issuer_orders
            super(**options)
          end

          def available?(endpoint)
            return !@issuer_orders.nil? if endpoint == :issuer_orders

            super
          end

          def create_issuer_order(request)
            body = @request_parser.request_document(request)
            order, created = @issuer_orders.create(
              customer_user_id: body.fetch("actor_user_id"),
              sku: body.fetch("sku"),
              denomination: body.fetch("denomination"),
              idempotency_key: body.fetch("idempotency_key")
            )
            resource_response(created ? 201 : 200, present_issuer_order(order))
          end

          def find_issuer_order(request, id:)
            order = @issuer_orders.find_for_customer(id, customer_user_id: request.params["actor_user_id"])
            resource_response(200, present_issuer_order(order))
          end

          def cancel_issuer_order(request, id:)
            body = @request_parser.request_document(request)
            order = @issuer_orders.cancel(id, customer_user_id: body.fetch("actor_user_id"))
            resource_response(200, present_issuer_order(order))
          end
        end

        EndpointHandler.prepend(IssuerOrderEndpoints)
      end
    end
  end
end
