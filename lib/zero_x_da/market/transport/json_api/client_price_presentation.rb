# frozen_string_literal: true

require_relative "endpoint_handler"

module ZeroXDA
  module Market
    module Transport
      class JSONAPI
        # Applies client-facing presentation only at the buyer transport
        # boundary. Exact FX conversion remains available to domain services.
        module ClientPricePresentation
          private

          def present_localized_price(price, currency)
            amount = localized_client_amount(price.amount_usdt, currency)
            {
              "amount" => decimal_string(amount),
              "currency" => currency,
              "amount_usdt" => decimal_string(price.amount_usdt),
              "source" => price.source,
              "edited_by_user_id" => price.set_by_user_id,
              "applied_at" => timestamp(price.created_at)
            }
          end

          def present_effective_client_price(price, amount_usdt:, currency:)
            presented = present_localized_price(price, currency)
            return presented if amount_usdt == price.amount_usdt

            presented.merge(
              "amount" => decimal_string(localized_client_amount(amount_usdt, currency)),
              "amount_usdt" => decimal_string(amount_usdt)
            )
          end

          def localized_client_amount(amount_usdt, currency)
            return amount_usdt unless @localization

            @localization.present_client_price(
              amount_usdt: amount_usdt,
              currency: currency
            )
          end
        end

        EndpointHandler.prepend(ClientPricePresentation)
      end
    end
  end
end
