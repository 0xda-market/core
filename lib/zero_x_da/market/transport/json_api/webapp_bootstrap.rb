# frozen_string_literal: true

require "digest"
require "json"
require "time"

module ZeroXDA
  module Market
    module Transport
      class JSONAPI
        class EndpointHandler
          WEBAPP_BOOTSTRAP_SCHEMA_VERSION = 1

          # Returns the complete active sellable catalog in one response. The
          # browser owns pagination, search and filtering for the lifetime of
          # this immutable snapshot; checkout still revalidates through core.
          def webapp_bootstrap(request)
            currency = @request_parser.requested_currency(request)
            locale = @request_parser.requested_locale(request)
            products = @catalog.products(locale: locale)
            prices = @pricing ? @pricing.current_prices : {}
            available_skus = @listings ? @listings.available_skus.to_h { |sku| [sku, true] } : nil
            data = products.map do |product|
              price = prices[product.sku]
              available = !price.nil? && (available_skus.nil? || available_skus.key?(product.sku))
              present_webapp_product(
                product,
                price: available ? price : nil,
                currency: currency,
                available: available
              )
            end
            snapshot_id = Digest::SHA256.hexdigest(JSON.generate(data))

            json_response(
              200,
              {
                "data" => data,
                "meta" => {
                  "schema_version" => WEBAPP_BOOTSTRAP_SCHEMA_VERSION,
                  "snapshot_id" => snapshot_id,
                  "generated_at" => Time.now.utc.iso8601(6),
                  "count" => data.length,
                  "available_count" => data.count { |resource| resource.dig("attributes", "available") },
                  "complete" => true,
                  "pagination" => "client",
                  "currency" => currency,
                  "locale" => locale
                }
              }
            )
          end

          private

          def present_webapp_product(product, price:, currency:, available:)
            resource = present_product(product)
            attributes = resource.fetch("attributes").dup
            attributes.delete("updated_by_user_id")
            attributes.delete("price_updated_by_user_id")
            attributes["available"] = available
            attributes["price"] = price && public_webapp_price(price, currency)
            resource.merge("attributes" => attributes)
          end

          def public_webapp_price(price, currency)
            present_localized_price(price, currency).reject do |key, _value|
              key == "edited_by_user_id"
            end
          end
        end
      end
    end
  end
end
