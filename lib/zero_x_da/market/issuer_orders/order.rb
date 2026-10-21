# frozen_string_literal: true

require_relative "../core/contracts"
require_relative "../core/records"

module ZeroXDA
  module Market
    module IssuerOrders
      # A purchase paid in an issuer denomination. The issuer decides the
      # outcome; this record only snapshots the request and follows that
      # decision through an explicit state machine.
      Event = Struct.new(:order_id, :from_status, :to_status, :actor, :data, :created_at, keyword_init: true)

      class Order
        STATUSES = %w[pending processing fulfilled rejected cancelled].freeze
        TERMINAL_STATUSES = %w[fulfilled rejected cancelled].freeze
        IDEMPOTENCY_KEY_PATTERN = /\A[A-Za-z0-9._:-]{8,128}\z/
        REJECTION_CODE_PATTERN = /\A[a-z][a-z0-9_]{1,63}\z/

        attr_reader :id, :customer_user_id, :idempotency_key, :sku, :denomination, :issuer,
                    :amount_minor, :price_id, :recipient_subject, :status, :issuer_reference,
                    :rejection_code, :created_at, :updated_at, :claimed_at, :completed_at, :version

        def initialize(
          id:, customer_user_id:, idempotency_key:, sku:, denomination:, issuer:, amount_minor:,
          price_id:, recipient_subject:, created_at:, status: "pending", issuer_reference: nil,
          rejection_code: nil, updated_at: created_at, claimed_at: nil, completed_at: nil, version: 0
        )
          @id = Core::RecordSupport.identifier(id, field: "issuer order id")
          @customer_user_id = Core::RecordSupport.identifier(customer_user_id, field: "customer user id")
          @idempotency_key = pattern(idempotency_key, IDEMPOTENCY_KEY_PATTERN, field: "idempotency_key")
          @sku = Core::RecordSupport.identifier(sku, field: "sku")
          @denomination = Core::RecordSupport.identifier(denomination, field: "denomination")
          @issuer = Core::RecordSupport.identifier(issuer, field: "issuer")
          @amount_minor = positive_integer(amount_minor, field: "amount_minor")
          @price_id = positive_integer(price_id, field: "price_id")
          @recipient_subject = bounded_string(recipient_subject, field: "recipient_subject")
          raise ArgumentError, "issuer order status is invalid" unless STATUSES.include?(status)

          @status = status.dup.freeze
          @issuer_reference = issuer_reference && bounded_string(issuer_reference, field: "issuer_reference")
          @rejection_code = rejection_code && pattern(rejection_code, REJECTION_CODE_PATTERN, field: "rejection code")
          @created_at = Core::RecordSupport.time(created_at, field: "created_at")
          @updated_at = Core::RecordSupport.time(updated_at, field: "updated_at")
          @claimed_at = claimed_at && Core::RecordSupport.time(claimed_at, field: "claimed_at")
          @completed_at = completed_at && Core::RecordSupport.time(completed_at, field: "completed_at")
          @version = Core::RecordSupport.non_negative_integer(version, field: "version")
          validate_outcome!
          freeze
        end

        def terminal?
          TERMINAL_STATUSES.include?(@status)
        end

        def claim(at:)
          transition!("claim", from: %w[pending])
          copy(status: "processing", claimed_at: at, updated_at: at)
        end

        def cancel(at:)
          transition!("cancel", from: %w[pending])
          copy(status: "cancelled", completed_at: at, updated_at: at)
        end

        def fulfil(reference:, at:)
          transition!("fulfil", from: %w[processing])
          copy(status: "fulfilled", issuer_reference: reference, completed_at: at, updated_at: at)
        end

        def reject(code:, at:)
          transition!("reject", from: %w[pending processing])
          copy(status: "rejected", rejection_code: code, completed_at: at, updated_at: at)
        end

        def to_h
          {
            id: @id, customer_user_id: @customer_user_id, idempotency_key: @idempotency_key, sku: @sku,
            denomination: @denomination, issuer: @issuer, amount_minor: @amount_minor, price_id: @price_id,
            recipient_subject: @recipient_subject, status: @status, issuer_reference: @issuer_reference,
            rejection_code: @rejection_code, created_at: @created_at, updated_at: @updated_at,
            claimed_at: @claimed_at, completed_at: @completed_at, version: @version
          }
        end

        private

        def copy(**changes)
          self.class.new(**to_h, **changes, version: @version + 1)
        end

        def transition!(event, from:)
          return if from.include?(@status)

          raise Core::InvalidTransition.new(resource: "issuer_order", id: @id, from: @status, event: event)
        end

        def validate_outcome!
          unless (@status == "fulfilled") == !@issuer_reference.nil?
            raise ArgumentError, "only a fulfilled issuer order carries an issuer reference"
          end
          unless (@status == "rejected") == !@rejection_code.nil?
            raise ArgumentError, "only a rejected issuer order carries a rejection code"
          end
          return if terminal? == !@completed_at.nil?

          raise ArgumentError, "only a terminal issuer order carries completed_at"
        end

        def pattern(value, expression, field:)
          raise ArgumentError, "#{field} is invalid" unless value.is_a?(String) && expression.match?(value)

          value.dup.freeze
        end

        def bounded_string(value, field:)
          unless value.is_a?(String) && value.length.between?(1, 256)
            raise ArgumentError, "#{field} must be 1 to 256 characters"
          end

          value.dup.freeze
        end

        def positive_integer(value, field:)
          raise ArgumentError, "#{field} must be a positive integer" unless value.is_a?(Integer) && value.positive?

          value
        end
      end
    end
  end
end
