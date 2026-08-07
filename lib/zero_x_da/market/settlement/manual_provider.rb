# frozen_string_literal: true

require "digest"
require "time"
require_relative "contracts"
require_relative "record"
require_relative "memory_store"

module ZeroXDA
  module Market
    module Settlement
      class ManualProvider
        attr_reader :key, :default_cost

        def initialize(
          key: "manual.settlement.default", clock:, store: MemoryStore.new,
          variable_fee_bps: 0, fixed_cost_usdt: 0, tolerance_bps: 0
        )
          @key = Core::RecordSupport.identifier(key, field: "settlement provider key")
          @clock = clock
          @store = store
          @default_cost = Core::Contracts::CostResult.new(
            variable_fee_bps: variable_fee_bps,
            fixed_cost_usdt: fixed_cost_usdt
          )
          @tolerance_bps = Integer(tolerance_bps)
          raise ArgumentError, "tolerance_bps must be between 0 and 9999" unless @tolerance_bps.between?(0, 9_999)
        end

        def cost(quote:)
          raise ArgumentError, "quote is required" unless quote
          @default_cost
        end

        def charge(order:, idempotency_key:)
          payment = order.payment || raise(Core::ProviderContractError.new("settlement requires an order payment document"))
          currency = payment.fetch("currency").to_s.upcase
          unless currency == "USDT"
            raise Core::ProviderContractError.new("manual settlement v1 requires canonical USDT")
          end

          existing = @store.find_by_order(order.id)
          return result_for(existing) if existing

          key = Core::RecordSupport.identifier(idempotency_key.to_s, field: "idempotency key")
          now = current_time
          settlement = Record.new(
            id: "settlement-#{Digest::SHA256.hexdigest(key)[0, 32]}",
            order_id: order.id,
            provider_key: @key,
            expected_usdt: payment.fetch("amount"),
            currency: currency,
            tolerance_bps: @tolerance_bps,
            idempotency_key: key,
            expires_at: payment["expires_at"] && Time.iso8601(payment.fetch("expires_at")),
            created_at: now
          )
          @store.insert(settlement)
          append_event(settlement)
          result_for(settlement)
        rescue Core::Conflict => error
          raise unless error.code == "duplicate_record"
          result_for(@store.find_by_order(order.id) || raise)
        end

        def verify(settlement:)
          current = @store.fetch(settlement.id)
          result_for(current)
        end

        def find_by_order(order_id)
          @store.find_by_order(order_id)
        end

        # Trusted operator action. It is intentionally outside the generic
        # settlement port: automated adapters will observe their own provider.
        def confirm(order_id:, reference:, data: {}, received_usdt: nil)
          @store.transaction do |store|
            current = store.find_by_order(order_id) || raise(Core::NotFound.new("settlement", order_id))
            next current if current.settled?
            unless current.pending?
              raise Core::InvalidTransition.new(resource: "settlement", id: current.id, from: current.state, event: "confirm")
            end

            now = current_time
            if current.expired?(at: now)
              replacement = rebuild(current, state: "expired", updated_at: now)
              store.replace(replacement, expected_version: current.version)
              append_event(replacement, store: store)
              raise Core::Conflict.new("settlement has expired", code: "payment_expired", details: { order_id: order_id.to_s })
            end

            received = received_usdt.nil? ? current.expected_usdt : BigDecimal(received_usdt.to_s)
            unless within_tolerance?(current, received)
              replacement = rebuild(
                current, state: "failed", received_usdt: received,
                external_reference: reference, provider_data: data, updated_at: now
              )
              store.replace(replacement, expected_version: current.version)
              append_event(replacement, store: store)
              raise Core::Conflict.new("settlement amount is outside tolerance", code: "settlement_amount_mismatch", details: { settlement_id: current.id })
            end

            replacement = rebuild(
              current, state: "settled", received_usdt: received,
              external_reference: reference, provider_data: data, updated_at: now
            )
            store.replace(replacement, expected_version: current.version)
            append_event(replacement, store: store)
            replacement
          end
        end

        private

        def result_for(settlement)
          case settlement.state
          when "pending"
            Core::Contracts::PendingSettlement.new(settlement: settlement, reference: settlement.id, data: { state: settlement.state })
          when "settled"
            Core::Contracts::SettlementResult.new(settlement: settlement, reference: settlement.external_reference, data: settlement.provider_data)
          when "expired"
            raise Core::Conflict.new("settlement has expired", code: "payment_expired", details: { settlement_id: settlement.id })
          else
            raise Core::ProviderFailure.new("settlement failed", code: "settlement_failed", retryable: false, details: { settlement_id: settlement.id })
          end
        end

        def within_tolerance?(settlement, received)
          return false unless received.finite? && !received.negative?
          difference = (received - settlement.expected_usdt).abs
          maximum = settlement.expected_usdt * BigDecimal(settlement.tolerance_bps.to_s) / BigDecimal("10000")
          difference <= maximum
        rescue ArgumentError
          false
        end

        def rebuild(record, **changes)
          attributes = {
            id: record.id, order_id: record.order_id, provider_key: record.provider_key,
            state: record.state, expected_usdt: record.expected_usdt, received_usdt: record.received_usdt,
            currency: record.currency, tolerance_bps: record.tolerance_bps, idempotency_key: record.idempotency_key,
            external_reference: record.external_reference, provider_data: record.provider_data,
            expires_at: record.expires_at, created_at: record.created_at, updated_at: record.updated_at,
            version: record.version
          }
          Record.new(**attributes.merge(changes, version: record.version + 1))
        end

        def append_event(record, store: @store)
          store.append_event(
            "settlement_id" => record.id,
            "state" => record.state,
            "provider_data" => record.provider_data,
            "observed_at" => record.updated_at.iso8601(6)
          )
        end

        def current_time
          value = @clock.call
          raise Core::ProviderContractError.new("clock must return a Time") unless value.is_a?(Time)
          value.getutc
        end
      end
    end
  end
end
