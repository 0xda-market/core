# frozen_string_literal: true

module ZeroXDA
  module Market
    module Transport
      # Shared JSON shape for an issuer order on the client and issuer APIs.
      module IssuerOrderPresenter
        private

        # The issuer sees the full order. A customer does not see which of its
        # channel accounts selected the recipient.
        def present_issuer_order(order, audience: :issuer)
          resource = {
            "type" => "issuer_order",
            "id" => order.id,
            "attributes" => {
              "sku" => order.sku,
              "denomination" => order.denomination,
              "issuer" => order.issuer,
              "amount_minor" => order.amount_minor,
              "price_id" => order.price_id,
              "recipient_subject" => order.recipient_subject,
              "link_provider" => order.link_provider,
              "link_provider_user_id" => order.link_provider_user_id,
              "status" => order.status,
              "issuer_reference" => order.issuer_reference,
              "rejection_code" => order.rejection_code,
              "created_at" => order.created_at.iso8601(6),
              "updated_at" => order.updated_at.iso8601(6),
              "claimed_at" => order.claimed_at&.iso8601(6),
              "completed_at" => order.completed_at&.iso8601(6),
              "term" => order.term_months && { "months" => order.term_months, "policy" => order.term_policy },
              "authorization_expires_at" => order.authorization_expires_at&.iso8601(6)
            }
          }
          return resource if audience == :issuer

          resource["attributes"] = resource["attributes"].except("link_provider_user_id")
          resource
        end

      end
    end
  end
end
