# frozen_string_literal: true

require "bigdecimal"
require_relative "../core/contracts"

module ZeroXDA
  module Market
    module Settlement
      class Record
        STATES = %w[pending settled failed expired].freeze

        attr_reader :id, :order_id, :provider_key, :state, :expected_usdt,
                    :received_usdt, :currency, :tolerance_bps, :idempotency_key,
                    :external_reference, :provider_data, :expires_at,
                    :created_at, :updated_at, :version

        def initialize(
          id:, order_id:, provider_key:, state: "pending", expected_usdt:,
          received_usdt: nil, currency: "USDT", tolerance_bps: 0,
          idempotency_key:, external_reference: nil, provider_data: {},
          expires_at: nil, created_at:, updated_at: created_at, version: 0
        )
          raise ArgumentError, "settlement state is invalid" unless STATES.include?(state.to_s)

          @id = Core::RecordSupport.identifier(id.to_s, field: "settlement id")
          @order_id = Core::RecordSupport.identifier(order_id.to_s, field: "order id")
          @provider_key = Core::RecordSupport.identifier(provider_key.to_s, field: "settlement provider key")
          @state = state.to_s.dup.freeze
          @expected_usdt = positive_decimal(expected_usdt, "expected_usdt")
          @received_usdt = received_usdt.nil? ? nil : non_negative_decimal(received_usdt, "received_usdt")
          @currency = Core::RecordSupport.identifier(currency.to_s.upcase, field: "settlement currency")
          @tolerance_bps = Integer(tolerance_bps)
          raise ArgumentError, "tolerance_bps must be between 0 and 9999" unless @tolerance_bps.between?(0, 9_999)

          @idempotency_key = Core::RecordSupport.identifier(idempotency_key.to_s, field: "idempotency key")
          @external_reference = external_reference && Core::RecordSupport.identifier(external_reference.to_s, field: "external reference")
          @provider_data = Core::RecordSupport.document(provider_data, field: "provider data")
          @expires_at = Core::RecordSupport.optional_time(expires_at, field: "settlement expires_at")
          @created_at = Core::RecordSupport.time(created_at, field: "created_at")
          @updated_at = Core::RecordSupport.time(updated_at, field: "updated_at")
          raise ArgumentError, "settlement version must be a non-negative integer" unless version.is_a?(Integer) && version >= 0

          @version = version
          freeze
        end

        def pending? = state == "pending"
        def settled? = state == "settled"
        def expired?(at:) = expires_at && expires_at <= at

        private

        def positive_decimal(value, field)
          number = BigDecimal(value.to_s)
          raise ArgumentError, "#{field} must be positive" unless number.finite? && number.positive?
          number
        rescue ArgumentError
          raise ArgumentError, "#{field} must be a finite positive decimal"
        end

        def non_negative_decimal(value, field)
          number = BigDecimal(value.to_s)
          raise ArgumentError, "#{field} must not be negative" unless number.finite? && !number.negative?
          number
        rescue ArgumentError
          raise ArgumentError, "#{field} must be a finite non-negative decimal"
        end
      end
    end
  end
end
