# frozen_string_literal: true

require "bigdecimal"
require_relative "../core/records"

module ZeroXDA
  module Market
    module Listings
      class Reservation
        STATUSES = %w[active committed released].freeze

        attr_reader :id,
                    :listing_id,
                    :customer_user_id,
                    :quote_id,
                    :order_id,
                    :quantity,
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
          expires_at:,
          order_id: nil,
          status: "active",
          created_at:,
          updated_at: created_at,
          version: 0
        )
          raise ArgumentError, "reservation status is invalid" unless STATUSES.include?(status)
          if status == "committed" && order_id.to_s.empty?
            raise ArgumentError, "committed reservation requires an order id"
          end

          @id = Core::RecordSupport.identifier(id.to_s, field: "reservation id")
          @listing_id = Core::RecordSupport.identifier(listing_id.to_s, field: "listing id")
          @customer_user_id = Core::RecordSupport.identifier(
            customer_user_id.to_s,
            field: "customer user id"
          )
          @quote_id = Core::RecordSupport.identifier(quote_id.to_s, field: "quote id")
          @order_id = order_id && Core::RecordSupport.identifier(order_id.to_s, field: "order id")
          @quantity = decimal(quantity)
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

        def expired?(at:)
          active? && at >= expires_at
        end

        private

        def decimal(value)
          number = value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
          maximum = BigDecimal("1e16")
          unless number.finite? && number.positive? && number < maximum && number.round(12) == number
            raise ArgumentError, "reservation quantity must be a positive decimal with at most 12 fractional digits"
          end

          number
        rescue ArgumentError
          raise ArgumentError, "reservation quantity must be a positive decimal with at most 12 fractional digits"
        end
      end
    end
  end
end
