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
              customer_user_id: verified_customer_id(request),
              sku: body.fetch("sku"),
              denomination: body.fetch("denomination"),
              idempotency_key: body.fetch("idempotency_key")
            )
            resource_response(created ? 201 : 200, present_issuer_order(order, audience: :customer))
          end

          def find_issuer_order(request, id:)
            order = @issuer_orders.find_for_customer(id, customer_user_id: verified_customer_id(request))
            resource_response(200, present_issuer_order(order, audience: :customer))
          end

          # The issuer subject stays private; the channel gets only the public
          # handle to show, or linked: false to offer signing in with the issuer.
          def issuer_account_status(request, issuer:)
            status = @issuer_orders.account_status(customer_user_id: verified_customer_id(request), issuer: issuer)
            resource_response(
              200,
              { "type" => "issuer_account", "id" => issuer,
                "attributes" => status.transform_keys(&:to_s).except("issuer") }
            )
          end

          def cancel_issuer_order(request, id:)
            @request_parser.ensure_empty_or_object_body(request)
            order = @issuer_orders.cancel(id, customer_user_id: verified_customer_id(request))
            resource_response(200, present_issuer_order(order, audience: :customer))
          end

          private

          # Only the channel adapter can set this Rack env key after validating
          # provider-signed proof. Never derive it from HTTP headers or params.
          def verified_customer_id(request)
            request.get_header("zero_x_da.market.verified_customer_id")
          end
        end

        EndpointHandler.prepend(IssuerOrderEndpoints)
      end
    end
  end
end
