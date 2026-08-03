# frozen_string_literal: true

module ZeroXDA
  module Market
    module Transport
      class JSONAPI
        module LiquidityCatalogEndpoints
          def products(request)
            currency = @request_parser.requested_currency(request)
            locale = @request_parser.requested_locale(request)
            products = @catalog.products(locale: locale)
            prices = @pricing ? @pricing.current_prices : {}
            available_skus = @listings ? @listings.available_skus.to_h { |sku| [sku, true] } : nil
            data = products.map do |product|
              resource = present_product(product)
              available = available_skus.nil? || available_skus.key?(product.sku)
              price = available && prices[product.sku]
              resource["attributes"]["available"] = available
              resource["attributes"]["price"] = price && present_localized_price(price, currency)
              resource
            end
            json_response(
              200,
              {
                "data" => data,
                "meta" => {
                  "count" => products.length,
                  "available_count" => data.count { |resource| resource.dig("attributes", "available") },
                  "currency" => currency,
                  "locale" => locale
                }
              }
            )
          end

          private

          def present_listing(listing)
            resource = super
            resource.fetch("attributes").merge!(
              "available_quantity" => decimal_string(listing.available_quantity),
              "reserved_quantity" => decimal_string(listing.reserved_quantity),
              "sold_quantity" => decimal_string(listing.sold_quantity)
            )
            resource
          end
        end

        EndpointHandler.prepend(LiquidityCatalogEndpoints)
      end
    end
  end
end
