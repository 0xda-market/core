# frozen_string_literal: true

require "bigdecimal"
require_relative "../core/records"

module ZeroXDA
  module Market
    module Listings
      class Reservation
        STATUSES = %w[active payment_pending committed released].freeze
        CURRENCY_PATTERN = /\A[A-Z][A-Z0-9]{2,9}\z/

        attr_reader :id,
                    :listing_id,
                    :customer_user_id,
                    :quote_id,
                    :order_id,
                    :quantity,
                    :supply_unit_price,
                    :supply_currency,
                    :status,
                    :expires_at,
                    :created_at,
                    :updated_at,
                    :version

        def initialize(
          id:,
          listing_id:,
          customer_user_id:,
          quote_id:,
          quantity:,
          supply_unit_price:,
          supply_currency:,
          expires_at:,
          order_id: nil,
          status: "active",
          created_at:,
          updated_at: created_at,
          version: 0
        )
          raise ArgumentError, "reservation status is invalid" unless STATUSES.include?(status)
          if %w[payment_pending committed].include?(status) && order_id.to_s.empty?
            raise ArgumentError, "#{status.tr("_", "-")} reservation requires an order id"
          end

          @id = Core::RecordSupport.identifier(id.to_s, field: "reservation id")
          @listing_id = Core::RecordSupport.identifier(listing_id.to_s, field: "listing id")
          @customer_user_id = Core::RecordSupport.identifier(
            customer_user_id.to_s,
            field: "customer user id"
          )
          @quote_id = Core::RecordSupport.identifier(quote_id.to_s, field: "quote id")
          @order_id = order_id && Core::RecordSupport.identifier(order_id.to_s, field: "order id")
          @quantity = decimal(quantity, field: "reservation quantity", scale: 12)
          @supply_unit_price = decimal(supply_unit_price, field: "supply unit price", scale: 8)
          @supply_currency = supply_currency.to_s.upcase.freeze
          raise ArgumentError, "supply currency is invalid" unless CURRENCY_PATTERN.match?(@supply_currency)
          @status = status.dup.freeze
          @expires_at = Core::RecordSupport.time(expires_at, field: "expires_at")
          @created_at = Core::RecordSupport.time(created_at, field: "created_at")
          @updated_at = Core::RecordSupport.time(updated_at, field: "updated_at")
          @version = Core::RecordSupport.non_negative_integer(version, field: "version")
          freeze
        end

        def active?
          status == "active"
        end

        def payment_pending?
          status == "payment_pending"
        end

        def reserving?
          active? || payment_pending?
        end

        def expired?(at:)
          reserving? && at >= expires_at
        end

        private

        def decimal(value, field:, scale:)
          number = value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
          maximum = BigDecimal("1e16")
          unless number.finite? && number.positive? && number < maximum && number.round(scale) == number
            raise ArgumentError, "#{field} must be a positive decimal with at most #{scale} fractional digits"
          end

          number
        rescue ArgumentError
          raise ArgumentError, "#{field} must be a positive decimal with at most #{scale} fractional digits"
        end
      end
    end
  end
end
