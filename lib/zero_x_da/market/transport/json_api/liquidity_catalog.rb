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
            minimum_prices = available_minimum_client_prices_usdt
            data = products.map do |product|
              resource = present_product(product)
              available = minimum_prices.nil? || minimum_prices.key?(product.sku)
              price = prices[product.sku]
              amount_usdt = available && effective_client_price_amount(
                price,
                sku: product.sku,
                minimum_prices: minimum_prices
              )
              resource["attributes"]["available"] = available
              resource["attributes"]["price"] = amount_usdt && present_effective_client_price(
                price,
                amount_usdt: amount_usdt,
                currency: currency
              )
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
