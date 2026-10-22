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
            if request.params["preview_0x1"] == "true"
              products += @catalog.staged_0x1_subscriptions(locale: locale)
              products.sort_by!(&:position)
            end
            prices = @pricing ? @pricing.current_prices : {}
            executable_skus = available_executable_skus(prices)
            data = products.map do |product|
              resource = present_product(product)
              preview = product.status != "active"
              available = !preview && (executable_skus.nil? || executable_skus.key?(product.sku))
              price = preview ? nil : prices[product.sku]
              resource["attributes"]["preview"] = preview
              resource["attributes"]["available"] = available
              resource["attributes"]["price"] = price && present_effective_client_price(
                price,
                amount_usdt: price.amount_usdt,
                currency: currency
              )
              # Staged 0x1 subscriptions may show a read-only price, never
              # checkout terms. Keep price=nil and available=false while
              # entitlement fulfillment and payment are not configured.
              if preview && product.metadata["family"] == "0x1_subscription"
                staged_price = prices[product.sku]
                resource["attributes"]["preview_price"] = if staged_price
                  begin
                    present_effective_client_price(
                      staged_price,
                      amount_usdt: staged_price.amount_usdt,
                      currency: currency
                    )
                  rescue Localization::RateUnavailable
                    present_effective_client_price(
                      staged_price,
                      amount_usdt: staged_price.amount_usdt,
                      currency: "USDT"
                    )
                  end
                end
              end
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

          def present_listing(listing, **options)
            resource = super(listing, **options)
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
