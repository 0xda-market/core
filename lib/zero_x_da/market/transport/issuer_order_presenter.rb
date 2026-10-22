# frozen_string_literal: true

module ZeroXDA
  module Market
    module Transport
      # Shared JSON shape for an issuer order on the client and issuer APIs.
      module IssuerOrderPresenter
        private

        # The issuer sees the full order. A customer does not see the issuer's
        # internal account subject or which channel account selected it.
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
              "completed_at" => order.completed_at&.iso8601(6)
            }
          }
          return resource if audience == :issuer

          resource["attributes"] = resource["attributes"].except("recipient_subject", "link_provider_user_id")
          resource
        end

        def present_account_link(link)
          {
            "type" => "issuer_account_link",
            "id" => "#{link.provider}:#{link.provider_user_id}",
            "attributes" => {
              "issuer" => link.issuer,
              "provider" => link.provider,
              "provider_user_id" => link.provider_user_id,
              "subject" => link.subject,
              "pub_dress" => link.pub_dress,
              "linked_at" => link.linked_at.iso8601(6),
              "updated_at" => link.updated_at.iso8601(6)
            }
          }
        end
      end
    end
  end
end
