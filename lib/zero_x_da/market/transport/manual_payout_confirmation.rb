# frozen_string_literal: true

module ZeroXDA
  module Market
    module Transport
      class ManualAPI
        module PayoutConfirmation
          def initialize(broker_earnings: nil, **options)
            @broker_earnings = broker_earnings
            super(**options)
          end

          private

          def route(request)
            match = request.path_info.match(%r{\A/v1/broker/payouts/([^/]+)/confirm\z})
            if request.request_method == "POST" && match && @broker_earnings
              body = request_document(request)
              payout = @broker_earnings.confirm_payout(
                payout_id: match[1], external_reference: body.fetch("reference"),
                provider_data: body.fetch("data", {})
              )
              return json_response(200, {
                "data" => {
                  "type" => "broker_payout", "id" => payout.id,
                  "attributes" => {
                    "seller_user_id" => payout.seller_user_id,
                    "amount" => payout.amount.to_s("F"), "currency" => payout.currency,
                    "network" => payout.network, "destination" => payout.destination,
                    "status" => payout.state, "external_reference" => payout.external_reference,
                    "paid_at" => timestamp(payout.paid_at), "version" => payout.version
                  }
                }
              })
            end
            super
          end
        end

        prepend PayoutConfirmation
      end
    end
  end
end
