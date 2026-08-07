# frozen_string_literal: true

module ZeroXDA
  module Market
    module Transport
      class ManualAPI
        module PaymentConfirmation
          def initialize(marketplace: nil, settlement_provider: nil, **options)
            @marketplace = marketplace
            @settlement_provider = settlement_provider
            super(**options)
          end

          private

          def route(request)
            match = request.path_info.match(
              %r{\A/v1/market/orders/([^/]+)/payment/confirm\z}
            )
            if request.request_method == "POST" && match && @marketplace
              body = request_document(request)
              settlement = @settlement_provider&.confirm(
                order_id: match[1],
                reference: body.fetch("reference"),
                data: body.fetch("data", {}),
                received_usdt: body["received_usdt"]
              )
              result = @marketplace.confirm_payment(
                order_id: match[1],
                reference: body.fetch("reference"),
                data: body.fetch("data", {}),
                settlement: settlement
              )
              return json_response(
                200,
                { "data" => present_payment_confirmed_order(result) }
              )
            end

            super
          end

          def present_payment_confirmed_order(result)
            order = result.order
            reservation = result.reservation
            {
              "type" => "order",
              "id" => order.id,
              "attributes" => {
                "status" => order.status,
                "payment" => order.payment,
                "quantity" => reservation.quantity.to_s("F"),
                "inventory_status" => reservation.status,
                "progress" => order.progress,
                "result" => order.result,
                "failure" => order.failure,
                "created_at" => timestamp(order.created_at),
                "updated_at" => timestamp(order.updated_at)
              }
            }
          end
        end

        prepend PaymentConfirmation
      end
    end
  end
end
