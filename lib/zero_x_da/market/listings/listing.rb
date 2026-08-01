# frozen_string_literal: true

require "bigdecimal"
require_relative "../core/records"

module ZeroXDA
  module Market
    module Listings
      class Listing
        STATUSES = %w[active withdrawn].freeze
        CURRENCY_PATTERN = /\A[A-Z][A-Z0-9]{2,9}\z/

        attr_reader :id,
                    :seller_user_id,
                    :sku,
                    :quantity,
                    :price_amount,
                    :currency,
                    :status,
                    :created_at,
                    :updated_at,
                    :version

        def initialize(
          id:,
          seller_user_id:,
          sku:,
          quantity:,
          price_amount:,
          currency:,
          status: "active",
          created_at:,
          updated_at: created_at,
          version: 0
        )
          raise ArgumentError, "listing status is invalid" unless STATUSES.include?(status)

          @id = Core::RecordSupport.identifier(id.to_s, field: "listing id")
          @seller_user_id = Core::RecordSupport.identifier(seller_user_id.to_s, field: "seller user id")
          @sku = Core::RecordSupport.identifier(sku.to_s, field: "sku")
          @quantity = decimal(quantity, field: "quantity", precision: 28, scale: 12)
          @price_amount = decimal(price_amount, field: "price amount", precision: 28, scale: 8)
          @currency = currency.to_s.upcase.freeze
          raise ArgumentError, "currency is invalid" unless CURRENCY_PATTERN.match?(@currency)

          @status = status.dup.freeze
          @created_at = Core::RecordSupport.time(created_at, field: "created_at")
          @updated_at = Core::RecordSupport.time(updated_at, field: "updated_at")
          @version = Core::RecordSupport.non_negative_integer(version, field: "version")
          freeze
        end

        private

        def decimal(value, field:, precision:, scale:)
          number = value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
          maximum = BigDecimal("1e#{precision - scale}")
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
