# frozen_string_literal: true

require "bigdecimal"
require_relative "../core/records"

module ZeroXDA
  module Market
    module BrokerEarnings
      class Earning
        STATES = %w[pending available payout_queued paid void].freeze

        attr_reader :id, :order_id, :reservation_id, :listing_id, :seller_user_id,
                    :quantity, :ask_amount, :ask_currency, :payable_amount,
                    :payable_currency, :state, :payout_id, :available_at, :paid_at,
                    :created_at, :updated_at, :version

        def initialize(id:, order_id:, reservation_id:, listing_id:, seller_user_id:,
                       quantity:, ask_amount:, ask_currency:, payable_amount:,
                       payable_currency:, state: "pending", payout_id: nil,
                       available_at: nil, paid_at: nil, created_at:, updated_at: created_at,
                       version: 0)
          raise ArgumentError, "earning state is invalid" unless STATES.include?(state)
          @id = Core::RecordSupport.identifier(id.to_s, field: "earning id")
          @order_id = Core::RecordSupport.identifier(order_id.to_s, field: "order id")
          @reservation_id = Core::RecordSupport.identifier(reservation_id.to_s, field: "reservation id")
          @listing_id = Core::RecordSupport.identifier(listing_id.to_s, field: "listing id")
          @seller_user_id = Core::RecordSupport.identifier(seller_user_id.to_s, field: "seller user id")
          @quantity = decimal(quantity, field: "quantity", scale: 12)
          @ask_amount = decimal(ask_amount, field: "ask amount", scale: 8)
          @ask_currency = ask_currency.to_s.upcase.freeze
          @payable_amount = decimal(payable_amount, field: "payable amount", scale: 12)
          @payable_currency = payable_currency.to_s.upcase.freeze
          @state = state.dup.freeze
          @payout_id = payout_id&.to_s&.freeze
          @available_at = available_at && Core::RecordSupport.time(available_at, field: "available_at")
          @paid_at = paid_at && Core::RecordSupport.time(paid_at, field: "paid_at")
          @created_at = Core::RecordSupport.time(created_at, field: "created_at")
          @updated_at = Core::RecordSupport.time(updated_at, field: "updated_at")
          @version = Core::RecordSupport.non_negative_integer(version, field: "version")
          freeze
        end

        def to_h
          instance_variables.to_h { |name| [name.to_s.delete_prefix("@").to_sym, instance_variable_get(name)] }
        end

        private

        def decimal(value, field:, scale:)
          number = value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
          raise ArgumentError, "#{field} must be positive" unless number.finite? && number.positive? && number.round(scale) == number
          number
        rescue ArgumentError
          raise ArgumentError, "#{field} must be positive"
        end
      end
    end
  end
end
