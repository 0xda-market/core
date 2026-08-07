# frozen_string_literal: true

require "bigdecimal"
require_relative "../core/records"

module ZeroXDA
  module Market
    module BrokerEarnings
      class PayoutProfile
        attr_reader :seller_user_id, :currency, :network, :destination,
                    :minimum_payout_amount, :enabled, :created_at, :updated_at, :version

        def initialize(seller_user_id:, currency: "USDT", network:, destination:,
                       minimum_payout_amount: 0, enabled: true, created_at:, updated_at: created_at,
                       version: 0)
          @seller_user_id = Core::RecordSupport.identifier(seller_user_id.to_s, field: "seller user id")
          @currency = currency.to_s.upcase.freeze
          raise ArgumentError, "payout currency must be USDT" unless @currency == "USDT"

          @network = required_string(network, field: "network").upcase.freeze
          @destination = required_string(destination, field: "destination")
          @minimum_payout_amount = decimal(minimum_payout_amount, field: "minimum payout amount", allow_zero: true)
          raise ArgumentError, "enabled must be boolean" unless enabled == true || enabled == false

          @enabled = enabled
          @created_at = Core::RecordSupport.time(created_at, field: "created_at")
          @updated_at = Core::RecordSupport.time(updated_at, field: "updated_at")
          @version = Core::RecordSupport.non_negative_integer(version, field: "version")
          freeze
        end

        def to_h
          {
            seller_user_id: seller_user_id,
            currency: currency,
            network: network,
            destination: destination,
            minimum_payout_amount: minimum_payout_amount,
            enabled: enabled,
            created_at: created_at,
            updated_at: updated_at,
            version: version
          }
        end

        private

        def required_string(value, field:)
          normalized = value.to_s.strip
          raise ArgumentError, "#{field} is required" if normalized.empty?

          normalized.freeze
        end

        def decimal(value, field:, allow_zero: false)
          number = value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
          valid_sign = allow_zero ? number >= 0 : number.positive?
          raise ArgumentError, "#{field} is invalid" unless number.finite? && valid_sign && number.round(12) == number

          number
        rescue ArgumentError
          raise ArgumentError, "#{field} is invalid"
        end
      end

      class Payout
        STATES = %w[queued processing paid failed].freeze

        attr_reader :id, :seller_user_id, :currency, :network, :destination, :amount,
                    :state, :idempotency_key, :external_reference, :provider_data,
                    :created_at, :updated_at, :paid_at, :version

        def initialize(id:, seller_user_id:, currency: "USDT", network:, destination:, amount:,
                       state: "queued", idempotency_key:, external_reference: nil, provider_data: {},
                       created_at:, updated_at: created_at, paid_at: nil, version: 0)
          raise ArgumentError, "payout state is invalid" unless STATES.include?(state)

          @id = Core::RecordSupport.identifier(id.to_s, field: "payout id")
          @seller_user_id = Core::RecordSupport.identifier(seller_user_id.to_s, field: "seller user id")
          @currency = currency.to_s.upcase.freeze
          raise ArgumentError, "payout currency must be USDT" unless @currency == "USDT"

          @network = required_string(network, field: "network").upcase.freeze
          @destination = required_string(destination, field: "destination")
          @amount = decimal(amount, field: "amount")
          @state = state.dup.freeze
          @idempotency_key = Core::RecordSupport.identifier(idempotency_key.to_s, field: "idempotency key")
          @external_reference = optional_string(external_reference)
          @provider_data = Core::RecordSupport.document(provider_data, field: "provider_data")
          @created_at = Core::RecordSupport.time(created_at, field: "created_at")
          @updated_at = Core::RecordSupport.time(updated_at, field: "updated_at")
          @paid_at = Core::RecordSupport.optional_time(paid_at, field: "paid_at")
          @version = Core::RecordSupport.non_negative_integer(version, field: "version")

          if state == "paid"
            raise ArgumentError, "paid payout requires external reference" unless @external_reference
            raise ArgumentError, "paid payout requires paid_at" unless @paid_at
          elsif @paid_at
            raise ArgumentError, "only a paid payout may have paid_at"
          end

          freeze
        end

        def to_h
          {
            id: id,
            seller_user_id: seller_user_id,
            currency: currency,
            network: network,
            destination: destination,
            amount: amount,
            state: state,
            idempotency_key: idempotency_key,
            external_reference: external_reference,
            provider_data: provider_data,
            created_at: created_at,
            updated_at: updated_at,
            paid_at: paid_at,
            version: version
          }
        end

        private

        def required_string(value, field:)
          normalized = value.to_s.strip
          raise ArgumentError, "#{field} is required" if normalized.empty?

          normalized.freeze
        end

        def optional_string(value)
          return nil if value.nil?

          normalized = value.to_s.strip
          raise ArgumentError, "external reference is required" if normalized.empty?

          normalized.freeze
        end

        def decimal(value, field:)
          number = value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
          raise ArgumentError, "#{field} is invalid" unless number.finite? && number.positive? && number.round(12) == number

          number
        rescue ArgumentError
          raise ArgumentError, "#{field} is invalid"
        end
      end
    end
  end
end
