# frozen_string_literal: true

module ZeroXDA
  module Market
    module Transport
      # Shared JSON shape for an issuer order on the client and issuer APIs.
      module IssuerOrderPresenter
        private

        def present_issuer_order(order)
          {
            "type" => "issuer_order",
            "id" => order.id,
            "attributes" => {
              "sku" => order.sku,
              "denomination" => order.denomination,
              "issuer" => order.issuer,
              "amount_minor" => order.amount_minor,
              "price_id" => order.price_id,
              "recipient_subject" => order.recipient_subject,
              "status" => order.status,
              "issuer_reference" => order.issuer_reference,
              "rejection_code" => order.rejection_code,
              "created_at" => order.created_at.iso8601(6),
              "updated_at" => order.updated_at.iso8601(6),
              "claimed_at" => order.claimed_at&.iso8601(6),
              "completed_at" => order.completed_at&.iso8601(6)
            }
          }
        end
      end
    end
  end
end
