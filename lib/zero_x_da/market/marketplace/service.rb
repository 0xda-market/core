# frozen_string_literal: true

require "bigdecimal"
require_relative "../core/contracts"

module ZeroXDA
  module Market
    module Marketplace
      QuoteResult = Struct.new(
        :quote,
        :reservation,
        :product,
        :unit_price_usdt,
        :total_price_usdt,
        keyword_init: true
      )
      OrderResult = Struct.new(:order, :reservation, keyword_init: true)

      class Service
        CAPABILITY = "manual.fulfillment"

        def initialize(kernel:, catalog:, pricing:, listings:)
          @kernel = kernel
          @catalog = catalog
          @pricing = pricing
          @listings = listings
        end

        def quote(customer_user_id:, sku:, quantity: 1, context: {})
          raise ArgumentError, "context must be an object" unless context.is_a?(Hash)

          customer_id = Core::RecordSupport.identifier(
            customer_user_id.to_s,
            field: "customer user id"
          )
          product = @catalog.find_product(sku.to_s)
          unless product.status == "active" && product.marketable?
            raise Core::Conflict.new(
              "product is unavailable",
              code: "product_unavailable",
              details: { sku: product.sku }
            )
          end

          price = @pricing.current_prices[product.sku]
          unless price
            raise Core::Conflict.new(
              "product has no active client price",
              code: "product_unpriced",
              details: { sku: product.sku }
            )
          end

          requested_quantity = quantity_value(quantity)
          total_price = (price.amount_usdt * requested_quantity).round(6)
          intent = @kernel.create_intent(
            capability: CAPABILITY,
            payload: {
              "action" => "purchase",
              "product" => {
                "sku" => product.sku,
                "name" => product.name,
                "quantity" => requested_quantity.to_s("F"),
                "unit_price_usdt" => price.amount_usdt.to_s("F"),
                "total_price_usdt" => total_price.to_s("F"),
                "currency" => "USDT"
              }
            },
            context: stringify_keys(context).merge("customer_user_id" => customer_id)
          )
          quote = @kernel.quote_intent(intent.id)
          unless quote.expires_at
            raise Core::ProviderContractError.new(
              "marketplace quotes require an expiration"
            )
          end

          reservation = @listings.reserve(
            customer_user_id: customer_id,
            quote_id: quote.id,
            sku: product.sku,
            quantity: requested_quantity,
            expires_at: quote.expires_at
          )
          QuoteResult.new(
            quote: quote,
            reservation: reservation,
            product: product,
            unit_price_usdt: price.amount_usdt,
            total_price_usdt: total_price
          )
        end

        def accept(customer_user_id:, quote_id:)
          customer_id = normalized_customer_id(customer_user_id)
          order = @kernel.accept_quote(quote_id)
          reservation = @listings.commit(
            customer_user_id: customer_id,
            quote_id: quote_id,
            order_id: order.id
          )
          OrderResult.new(order: order, reservation: reservation)
        rescue StandardError
          begin
            @kernel.cancel_order(order.id) if order&.status == "accepted"
          rescue StandardError
            nil
          end
          raise
        end

        def find_order(customer_user_id:, order_id:)
          customer_id = normalized_customer_id(customer_user_id)
          reservation = @listings.reservation_for_order(order_id) ||
                        raise(Core::NotFound.new("marketplace_order", order_id))
          ensure_owner!(reservation, customer_id)
          OrderResult.new(order: @kernel.find_order(order_id), reservation: reservation)
        end

        def execute_order(customer_user_id:, order_id:)
          current = find_order(customer_user_id: customer_user_id, order_id: order_id)
          OrderResult.new(
            order: @kernel.execute_order(current.order.id),
            reservation: current.reservation
          )
        end

        def release_quote(customer_user_id:, quote_id:)
          @listings.release(
            customer_user_id: normalized_customer_id(customer_user_id),
            quote_id: quote_id
          )
        end

        private

        def normalized_customer_id(value)
          Core::RecordSupport.identifier(value.to_s, field: "customer user id")
        end

        def ensure_owner!(reservation, customer_id)
          return if reservation.customer_user_id == customer_id

          raise Core::Forbidden.new(
            "marketplace order belongs to another user",
            details: { order_id: reservation.order_id }
          )
        end

        def quantity_value(value)
          number = value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
          maximum = BigDecimal("1e16")
          unless number.finite? && number.positive? && number < maximum && number.round(12) == number
            raise ArgumentError, "quantity must be a positive decimal with at most 12 fractional digits"
          end

          number
        rescue ArgumentError
          raise ArgumentError, "quantity must be a positive decimal with at most 12 fractional digits"
        end

        def stringify_keys(document)
          document.each_with_object({}) { |(key, value), copy| copy[key.to_s] = value }
        end
      end
    end
  end
end
