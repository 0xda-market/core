# frozen_string_literal: true

require "time"
require_relative "contracts"

module ZeroXDA
  module Market
    module Core
      class Kernel
        INITIAL_ORDER_STATUSES = %w[accepted payment_pending].freeze

        def initialize(providers:, store:, clock:, id_generator:)
          @providers = providers.each_with_object({}) do |(capability, provider), copy|
            normalized = RecordSupport.capability(capability)
            copy[normalized] = Contracts.validate_provider!(provider)
          end.freeze
          @store = store
          @clock = clock
          @id_generator = id_generator
        end

        def create_intent(capability:, payload:, context: {})
          normalized = RecordSupport.capability(capability)
          provider_for(normalized)

          intent = Intent.new(
            id: next_id,
            capability: normalized,
            payload: payload,
            context: context,
            created_at: current_time
          )
          @store.insert(:intents, intent)
        end

        def find_intent(id)
          @store.fetch(:intents, id)
        end

        def quote_intent(id)
          intent = find_intent(id)
          provider = provider_for(intent.capability)
          result = invoke_quote(provider, intent)

          quote = Quote.new(
            id: next_id,
            intent_id: intent.id,
            provider_key: provider_key(provider),
            terms: result.terms,
            private_state: result.private_state,
            expires_at: result.expires_at,
            created_at: current_time
          )
          @store.insert(:quotes, quote)
        end

        def find_quote(id)
          @store.fetch(:quotes, id)
        end

        def accept_quote(id, initial_status: "accepted", payment: nil)
          normalized_status = initial_order_status(initial_status)
          if normalized_status == "payment_pending" && !payment.is_a?(Hash)
            raise ArgumentError, "payment-pending orders require payment details"
          end
          now = current_time

          @store.transaction do |store|
            quote = store.fetch(:quotes, id)
            order_id = order_id_for(quote)
            existing = store.find(:orders, order_id)
            next existing if existing

            raise QuoteExpired.new(quote.id) if quote.expired?(at: now)

            intent = store.fetch(:intents, quote.intent_id)
            order = Order.new(
              id: order_id,
              intent_id: intent.id,
              quote_id: quote.id,
              capability: intent.capability,
              provider_key: quote.provider_key,
              payload: intent.payload,
              context: intent.context,
              terms: quote.terms,
              private_state: quote.private_state,
              payment: payment,
              status: normalized_status,
              created_at: now
            )
            store.insert(:orders, order)
          end
        end

        def find_order(id)
          @store.fetch(:orders, id)
        end

        def confirm_order_payment(id, reference:, data: {})
          payment_reference = RecordSupport.identifier(reference.to_s, field: "payment reference")
          payment_data = RecordSupport.document(data, field: "payment data")
          now = current_time

          @store.transaction do |store|
            order = store.fetch(:orders, id)
            next order if payment_confirmed?(order)

            ensure_status!(order, allowed: ["payment_pending"], event: "confirm_payment")
            confirmed = rebuild_order(
              order,
              status: "accepted",
              payment: order.payment.merge(
                "status" => "confirmed",
                "reference" => payment_reference,
                "data" => payment_data,
                "confirmed_at" => now.iso8601(6)
              ),
              updated_at: now,
              version: order.version + 1
            )
            store.replace(:orders, confirmed, expected_version: order.version)
          end
        end

        def rollback_order_payment(id)
          now = current_time

          @store.transaction do |store|
            order = store.fetch(:orders, id)
            next order if order.status == "payment_pending"

            ensure_status!(order, allowed: ["accepted"], event: "rollback_payment")
            unless order.attempts.zero? && payment_confirmed?(order)
              raise InvalidTransition.new(
                resource: "order",
                id: order.id,
                from: order.status,
                event: "rollback_payment"
              )
            end

            pending_payment = order.payment.reject do |key, _value|
              %w[reference data confirmed_at].include?(key)
            end.merge("status" => "pending")
            reopened = rebuild_order(
              order,
              status: "payment_pending",
              payment: pending_payment,
              updated_at: now,
              version: order.version + 1
            )
            store.replace(:orders, reopened, expected_version: order.version)
          end
        end

        def execute_order(id)
          started = start_execution(id)
          return started if started.status == "succeeded"

          result = begin
            provider = provider_for(started.capability)
            ensure_provider_identity!(provider, started)
            execution = provider.execute(
              order: started,
              idempotency_key: "orders/#{started.id}/execute"
            )
            unless execution.is_a?(Contracts::ExecutionResult) ||
                   execution.is_a?(Contracts::PendingResult)
              raise ProviderContractError.new(
                "provider execution returned an invalid result"
              )
            end
            execution
          rescue ProviderFailure => error
            fail_execution(started, error)
            raise
          rescue StandardError => error
            wrapped = ProviderFailure.new(
              "provider execution raised an unexpected error",
              code: "unhandled_provider_error",
              retryable: false,
              details: { exception: error.class.name }
            )
            fail_execution(started, wrapped)
            raise wrapped
          end

          if result.is_a?(Contracts::PendingResult)
            defer_execution(started, result)
          else
            complete_execution(started, result)
          end
        end

        def cancel_order(id)
          now = current_time

          @store.transaction do |store|
            order = store.fetch(:orders, id)
            next order if order.status == "cancelled"

            ensure_status!(order, allowed: %w[accepted payment_pending], event: "cancel")
            cancelled = rebuild_order(
              order,
              status: "cancelled",
              updated_at: now,
              version: order.version + 1
            )
            store.replace(:orders, cancelled, expected_version: order.version)
          end
        end

        private

        def start_execution(id)
          now = current_time

          @store.transaction do |store|
            order = store.fetch(:orders, id)
            next order if order.status == "succeeded"

            retryable = order.status == "failed" && order.failure.fetch("retryable", false)
            unless %w[accepted pending].include?(order.status) || retryable
              raise InvalidTransition.new(
                resource: "order",
                id: order.id,
                from: order.status,
                event: "execute"
              )
            end

            attempts = order.status == "pending" ? order.attempts : order.attempts + 1
            started = rebuild_order(
              order,
              status: "processing",
              attempts: attempts,
              progress: nil,
              result: nil,
              failure: nil,
              updated_at: now,
              version: order.version + 1
            )
            store.replace(:orders, started, expected_version: order.version)
          end
        end

        def defer_execution(started, pending)
          now = current_time

          @store.transaction do |store|
            current = store.fetch(:orders, started.id)
            ensure_same_attempt!(started, current)

            deferred = rebuild_order(
              current,
              status: "pending",
              progress: {
                reference: pending.reference,
                data: pending.data
              },
              result: nil,
              failure: nil,
              updated_at: now,
              version: current.version + 1
            )
            store.replace(:orders, deferred, expected_version: current.version)
          end
        end

        def complete_execution(started, execution)
          now = current_time

          @store.transaction do |store|
            current = store.fetch(:orders, started.id)
            ensure_same_attempt!(started, current)

            completed = rebuild_order(
              current,
              status: "succeeded",
              progress: nil,
              result: {
                reference: execution.reference,
                data: execution.data
              },
              failure: nil,
              updated_at: now,
              version: current.version + 1
            )
            store.replace(:orders, completed, expected_version: current.version)
          end
        end

        def fail_execution(started, error)
          now = current_time

          @store.transaction do |store|
            current = store.fetch(:orders, started.id)
            ensure_same_attempt!(started, current)

            failed = rebuild_order(
              current,
              status: "failed",
              progress: nil,
              result: nil,
              failure: {
                code: error.code,
                retryable: error.retryable,
                details: error.details
              },
              updated_at: now,
              version: current.version + 1
            )
            store.replace(:orders, failed, expected_version: current.version)
          end
        rescue Conflict
          nil
        end

        def invoke_quote(provider, intent)
          result = provider.quote(intent: intent)
          return result if result.is_a?(Contracts::QuoteResult)

          raise ProviderContractError.new("provider quote returned an invalid result")
        rescue ProviderFailure
          raise
        rescue StandardError => error
          raise ProviderFailure.new(
            "provider quote raised an unexpected error",
            code: "unhandled_provider_error",
            retryable: false,
            details: { exception: error.class.name }
          )
        end

        def provider_for(capability)
          @providers.fetch(capability)
        rescue KeyError
          raise UnknownCapability.new(capability)
        end

        def provider_key(provider)
          RecordSupport.identifier(provider.key, field: "provider key")
        end

        def ensure_provider_identity!(provider, order)
          return if provider_key(provider) == order.provider_key

          raise ProviderFailure.new(
            "the order provider is unavailable",
            code: "provider_unavailable",
            retryable: true,
            details: { provider_key: order.provider_key }
          )
        end

        def ensure_same_attempt!(started, current)
          return if current.status == "processing" && current.attempts == started.attempts

          raise ConcurrencyConflict.new("order", current.id)
        end

        def ensure_status!(order, allowed:, event:)
          return if allowed.include?(order.status)

          raise InvalidTransition.new(
            resource: "order",
            id: order.id,
            from: order.status,
            event: event
          )
        end

        def payment_confirmed?(order)
          order.payment && order.payment["status"] == "confirmed"
        end

        def initial_order_status(value)
          status = value.to_s
          return status if INITIAL_ORDER_STATUSES.include?(status)

          raise ArgumentError, "initial order status is invalid"
        end

        def rebuild_order(order, **changes)
          attributes = {
            id: order.id,
            intent_id: order.intent_id,
            quote_id: order.quote_id,
            capability: order.capability,
            provider_key: order.provider_key,
            payload: order.payload,
            context: order.context,
            terms: order.terms,
            private_state: order.private_state,
            payment: order.payment,
            status: order.status,
            attempts: order.attempts,
            progress: order.progress,
            result: order.result,
            failure: order.failure,
            created_at: order.created_at,
            updated_at: order.updated_at,
            version: order.version
          }
          Order.new(**attributes.merge(changes))
        end

        def order_id_for(quote)
          "order:#{quote.id}"
        end

        def current_time
          value = @clock.call
          raise ProviderContractError.new("clock must return a Time") unless value.is_a?(Time)

          value.getutc
        end

        def next_id
          RecordSupport.identifier(@id_generator.call, field: "generated id")
        end
      end
    end
  end
end
