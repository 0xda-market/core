# frozen_string_literal: true

require "monitor"
require "time"
require_relative "../core/contracts"

module ZeroXDA
  module Market
    module Payments
      class MockProvider
        Intent = Struct.new(
          :id,
          :order_id,
          :amount,
          :currency,
          :expires_at,
          :status,
          :reference,
          :data,
          :confirmation,
          :failure,
          :created_at,
          :updated_at,
          keyword_init: true
        )

        TERMINAL_STATUSES = %w[succeeded failed expired].freeze

        def initialize(kernel:, confirmation_client:, clock:, id_generator:)
          @kernel = kernel
          @confirmation_client = confirmation_client
          @clock = clock
          @id_generator = id_generator
          @monitor = Monitor.new
          @intents = {}
          @intent_ids_by_order = {}
        end

        def create_intent(order_id:)
          normalized_order_id = Core::RecordSupport.identifier(
            order_id.to_s,
            field: "order id"
          )

          @monitor.synchronize do
            existing_id = @intent_ids_by_order[normalized_order_id]
            return @intents.fetch(existing_id) if existing_id

            order = @kernel.find_order(normalized_order_id)
            payment = order.payment
            unless order.status == "payment_pending" && payment&.fetch("status", nil) == "pending"
              raise Core::Conflict.new(
                "order is not awaiting payment",
                code: "payment_not_pending",
                details: { order_id: normalized_order_id, status: order.status }
              )
            end

            expires_at = Core::RecordSupport.optional_time(
              payment.fetch("expires_at"),
              field: "payment expires_at"
            )
            if expires_at && expires_at <= current_time
              raise Core::Conflict.new(
                "payment has expired",
                code: "payment_expired",
                details: { order_id: normalized_order_id }
              )
            end

            now = current_time
            intent = build_intent(
              id: Core::RecordSupport.identifier(
                @id_generator.call.to_s,
                field: "payment intent id"
              ),
              order_id: normalized_order_id,
              amount: payment.fetch("amount").to_s,
              currency: payment.fetch("currency").to_s,
              expires_at: expires_at,
              status: "pending",
              data: {},
              created_at: now,
              updated_at: now
            )
            @intents[intent.id] = intent
            @intent_ids_by_order[intent.order_id] = intent.id
            intent
          end
        end

        def fetch_intent(id)
          normalized_id = Core::RecordSupport.identifier(id.to_s, field: "payment intent id")
          @monitor.synchronize do
            @intents[normalized_id] || raise(Core::NotFound.new("payment_intent", normalized_id))
          end
        end

        def succeed(id, reference: nil, data: {})
          payment_data = Core::RecordSupport.document(data, field: "payment data")
          intent = begin_processing(id)
          return intent if intent.status == "succeeded"

          payment_reference = reference.to_s
          payment_reference = "mock/#{intent.id}" if payment_reference.empty?
          confirmation = @confirmation_client.confirm(
            order_id: intent.order_id,
            reference: payment_reference,
            data: payment_data.merge(
              "provider" => "mock",
              "payment_intent_id" => intent.id
            )
          )

          @monitor.synchronize do
            current = @intents.fetch(intent.id)
            completed = rebuild_intent(
              current,
              status: "succeeded",
              reference: payment_reference,
              data: payment_data,
              confirmation: confirmation,
              failure: nil,
              updated_at: current_time
            )
            @intents[intent.id] = completed
          end
        rescue StandardError
          restore_pending(intent) if intent
          raise
        end

        def fail(id, code: "mock_payment_failed", message: "mock payment failed", details: {})
          failure_details = Core::RecordSupport.document(details, field: "failure details")
          transition_terminal(
            id,
            status: "failed",
            failure: {
              "code" => code.to_s,
              "message" => message.to_s,
              "details" => failure_details
            }
          )
        end

        def expire(id)
          transition_terminal(
            id,
            status: "expired",
            failure: {
              "code" => "mock_payment_expired",
              "message" => "mock payment intent expired",
              "details" => {}
            }
          )
        end

        private

        def begin_processing(id)
          @monitor.synchronize do
            intent = fetch_intent(id)
            return intent if intent.status == "succeeded"
            unless intent.status == "pending"
              raise Core::Conflict.new(
                "payment intent cannot succeed while #{intent.status}",
                code: "invalid_payment_transition",
                details: { id: intent.id, status: intent.status, event: "succeed" }
              )
            end
            if intent.expires_at && intent.expires_at <= current_time
              expired = rebuild_intent(
                intent,
                status: "expired",
                failure: {
                  "code" => "mock_payment_expired",
                  "message" => "mock payment intent expired",
                  "details" => {}
                },
                updated_at: current_time
              )
              @intents[intent.id] = expired
              raise Core::Conflict.new(
                "payment intent has expired",
                code: "payment_expired",
                details: { id: intent.id }
              )
            end

            processing = rebuild_intent(intent, status: "processing", updated_at: current_time)
            @intents[intent.id] = processing
          end
        end

        def transition_terminal(id, status:, failure:)
          @monitor.synchronize do
            intent = fetch_intent(id)
            return intent if intent.status == status
            unless intent.status == "pending"
              raise Core::Conflict.new(
                "payment intent cannot become #{status} while #{intent.status}",
                code: "invalid_payment_transition",
                details: { id: intent.id, status: intent.status, event: status }
              )
            end

            terminal = rebuild_intent(
              intent,
              status: status,
              failure: failure,
              updated_at: current_time
            )
            @intents[intent.id] = terminal
          end
        end

        def restore_pending(intent)
          @monitor.synchronize do
            current = @intents[intent.id]
            return unless current&.status == "processing"

            @intents[intent.id] = rebuild_intent(
              current,
              status: "pending",
              updated_at: current_time
            )
          end
        end

        def build_intent(**attributes)
          Intent.new(**attributes).freeze
        end

        def rebuild_intent(intent, **changes)
          build_intent(**intent.to_h.merge(changes))
        end

        def current_time
          value = @clock.call
          value.is_a?(Time) ? value.utc : Time.parse(value.to_s).utc
        end
      end
    end
  end
end
