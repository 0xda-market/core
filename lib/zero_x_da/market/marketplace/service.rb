# frozen_string_literal: true

require "bigdecimal"
require "time"
require_relative "../core/contracts"

module ZeroXDA
  module Market
    module Marketplace
      QuoteResult = Struct.new(
        :quote,
        :reservation,
        :product,
        :recipient,
        :unit_price_usdt,
        :total_price_usdt,
        keyword_init: true
      )
      OrderResult = Struct.new(:order, :reservation, keyword_init: true)

      class Service
        CAPABILITY = "manual.fulfillment"
        CLIENT_PRICE_SCALE = 6

        def initialize(kernel:, catalog:, pricing:, listings:, settlement_provider: nil, recipient_resolver: nil)
          @kernel = kernel
          @catalog = catalog
          @pricing = pricing
          @listings = listings
          @settlement_provider = settlement_provider
          @recipient_resolver = recipient_resolver
        end

        def quote(customer_user_id:, sku:, quantity: 1, recipient: nil, context: {})
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

          requested_quantity = quantity_value(quantity)
          enforce_purchase_quantity!(product, requested_quantity)
          resolved_recipient = resolve_recipient(product, customer_id, recipient)

          price = @pricing.current_prices[product.sku]
          unless price
            raise Core::Conflict.new(
              "product has no active client price",
              code: "product_unpriced",
              details: { sku: product.sku }
            )
          end

          unit_price = price.amount_usdt.round(
            CLIENT_PRICE_SCALE,
            BigDecimal::ROUND_CEILING
          )
          total_price = (unit_price * requested_quantity).round(
            CLIENT_PRICE_SCALE,
            BigDecimal::ROUND_CEILING
          )
          payload = {
            "action" => "purchase",
            "product" => {
              "sku" => product.sku,
              "name" => product.name,
              "quantity" => requested_quantity.to_s("F"),
              "unit_price_usdt" => unit_price.to_s("F"),
              "total_price_usdt" => total_price.to_s("F"),
              "currency" => "USDT"
            }
          }
          payload["recipient"] = resolved_recipient.to_h if resolved_recipient
          intent = @kernel.create_intent(
            capability: CAPABILITY,
            payload: payload,
            context: stringify_keys(context).merge("customer_user_id" => customer_id)
          )
          quote = @kernel.quote_intent(intent.id)
          unless quote.expires_at
            raise Core::ProviderContractError.new(
              "marketplace quotes require an expiration"
            )
          end

          @kernel.settlement_cost(quote) if @kernel.respond_to?(:settlement_cost)

          reservation = @listings.reserve(
            customer_user_id: customer_id,
            quote_id: quote.id,
            sku: product.sku,
            quantity: requested_quantity,
            expires_at: quote.expires_at,
            client_total_price_usdt: total_price
          )
          QuoteResult.new(
            quote: quote,
            reservation: reservation,
            product: product,
            recipient: resolved_recipient,
            unit_price_usdt: unit_price,
            total_price_usdt: total_price
          )
        end

        def accept(customer_user_id:, quote_id:)
          customer_id = normalized_customer_id(customer_user_id)
          reservation = @listings.reservation_for_quote(quote_id) ||
                        raise(Core::NotFound.new("listing_reservation", quote_id))
          ensure_owner!(reservation, customer_id)
          quote = @kernel.find_quote(quote_id)
          intent = @kernel.find_intent(quote.intent_id)
          product = intent.payload.fetch("product")
          payment = {
            "status" => "pending",
            "amount" => product.fetch("total_price_usdt"),
            "currency" => product.fetch("currency"),
            "expires_at" => reservation.expires_at.iso8601(6),
            "idempotency_key" => "quotes/#{quote_id}/payment"
          }
          payment["settlement_required"] = true if @settlement_provider
          order = @kernel.accept_quote(
            quote_id,
            initial_status: "payment_pending",
            payment: payment
          )
          reservation = @listings.await_payment(
            customer_user_id: customer_id,
            quote_id: quote_id,
            order_id: order.id
          )
          @kernel.charge_settlement(order.id) if @settlement_provider
          OrderResult.new(order: order, reservation: reservation)
        rescue StandardError
          begin
            if order && %w[accepted payment_pending].include?(order.status)
              @kernel.cancel_order(order.id)
            end
            @listings.release(customer_user_id: customer_id, quote_id: quote_id) if reservation
          rescue StandardError
            nil
          end
          raise
        end

        def confirm_payment(order_id:, reference:, data: {}, settlement: nil)
          before = @kernel.find_order(order_id)
          unless before.payment
            raise Core::Conflict.new(
              "order does not require marketplace payment confirmation",
              code: "payment_not_required",
              details: { order_id: order_id.to_s }
            )
          end

          if settlement
            @kernel.verify_settlement(settlement)
          elsif @settlement_provider && before.payment["settlement_required"]
            @kernel.verify_settlement(@settlement_provider.find_by_order(order_id))
          end

          confirmed = @kernel.confirm_order_payment(
            order_id,
            reference: reference,
            data: data
          )
          begin
            reservation = @listings.commit_payment(order_id: order_id)
          rescue StandardError => error
            rollback_confirmed_payment(before, confirmed)
            expire_failed_payment(order_id, error)
            raise
          end

          OrderResult.new(
            order: @kernel.execute_order(order_id),
            reservation: reservation
          )
        end

        def find_order(customer_user_id:, order_id:)
          customer_id = normalized_customer_id(customer_user_id)
          reservation = @listings.reservation_for_order(order_id) ||
                        raise(Core::NotFound.new("marketplace_order", order_id))
          ensure_owner!(reservation, customer_id)
          order = @kernel.find_order(order_id)
          order = @kernel.cancel_order(order.id) if reservation.status == "released" && order.status == "payment_pending"
          OrderResult.new(order: order, reservation: reservation)
        end

        def execute_order(customer_user_id:, order_id:)
          current = find_order(customer_user_id: customer_user_id, order_id: order_id)
          unless current.reservation.status == "committed" && payment_satisfied?(current.order)
            raise Core::Conflict.new(
              "payment confirmation is required before fulfillment",
              code: "payment_required",
              details: { order_id: current.order.id }
            )
          end

          OrderResult.new(
            order: @kernel.execute_order(current.order.id),
            reservation: current.reservation
          )
        end

        def release_quote(customer_user_id:, quote_id:)
          customer_id = normalized_customer_id(customer_user_id)
          reservation = @listings.release(
            customer_user_id: customer_id,
            quote_id: quote_id
          )
          if reservation.order_id
            order = @kernel.find_order(reservation.order_id)
            @kernel.cancel_order(order.id) if order.status == "payment_pending"
          end
          reservation
        end

        private

        def enforce_purchase_quantity!(product, quantity)
          return unless product.metadata.dig("purchase", "quantity_mode") == "single"
          return if quantity == BigDecimal("1")

          raise Core::Conflict.new(
            "product can only be purchased one at a time",
            code: "single_quantity_only",
            details: { sku: product.sku, quantity: quantity.to_s("F") }
          )
        end

        def resolve_recipient(product, customer_id, recipient)
          policy = product.metadata.dig("purchase", "recipient")
          return nil unless policy
          unless @recipient_resolver
            raise Core::ProviderContractError.new("recipient resolver is required for this product")
          end

          @recipient_resolver.resolve(
            product: product,
            actor_user_id: customer_id,
            recipient: recipient
          )
        end

        def rollback_confirmed_payment(before, confirmed)
          return unless before&.status == "payment_pending" && confirmed&.status == "accepted"

          @kernel.rollback_order_payment(confirmed.id)
        rescue StandardError
          nil
        end

        def expire_failed_payment(order_id, error)
          return unless error.respond_to?(:code) && error.code == "payment_expired"

          order = @kernel.find_order(order_id)
          @kernel.cancel_order(order.id) if order.status == "payment_pending"
        rescue StandardError
          nil
        end

        def payment_satisfied?(order)
          order.payment.nil? || order.payment["status"] == "confirmed"
        end

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
