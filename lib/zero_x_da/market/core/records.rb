# frozen_string_literal: true

module ZeroXDA
  module Market
    module Core
      module RecordSupport
        CAPABILITY_PATTERN = /\A[a-z0-9][a-z0-9._:\/-]{0,127}\z/

        module_function

        def identifier(value, field:)
          unless value.is_a?(String) && !value.empty?
            raise ArgumentError, "#{field} must be a non-empty string"
          end

          value.dup.freeze
        end

        def capability(value)
          unless value.is_a?(String) && CAPABILITY_PATTERN.match?(value)
            raise ArgumentError, "capability must be a lowercase namespaced identifier"
          end

          value.dup.freeze
        end

        def document(value, field:)
          raise ArgumentError, "#{field} must be a JSON object" unless value.is_a?(Hash)

          deep_copy(value, path: field)
        end

        def optional_document(value, field:)
          value && document(value, field: field)
        end

        def time(value, field:)
          raise ArgumentError, "#{field} must be a Time" unless value.is_a?(Time)

          value.getutc.freeze
        end

        def optional_time(value, field:)
          value && time(value, field: field)
        end

        def non_negative_integer(value, field:)
          unless value.is_a?(Integer) && value >= 0
            raise ArgumentError, "#{field} must be a non-negative integer"
          end

          value
        end

        def deep_copy(value, path:)
          case value
          when Hash
            value.each_with_object({}) do |(raw_key, item), copy|
              unless raw_key.is_a?(String) || raw_key.is_a?(Symbol)
                raise ArgumentError, "#{path} contains a non-string key"
              end

              key = raw_key.to_s.encode(Encoding::UTF_8).freeze
              raise ArgumentError, "#{path} contains colliding keys" if copy.key?(key)

              copy[key] = deep_copy(item, path: "#{path}.#{key}")
            end.freeze
          when Array
            value.each_with_index.map do |item, index|
              deep_copy(item, path: "#{path}[#{index}]")
            end.freeze
          when String
            value.encode(Encoding::UTF_8).freeze
          when Integer, TrueClass, FalseClass, NilClass
            value
          when Float
            raise ArgumentError, "#{path} contains a non-finite number" unless value.finite?

            value
          else
            raise ArgumentError, "#{path} contains a non-JSON value"
          end
        rescue EncodingError
          raise ArgumentError, "#{path} contains invalid UTF-8"
        end
        private_class_method :deep_copy
      end

      class Intent
        attr_reader :id, :capability, :payload, :context, :created_at, :version

        def initialize(id:, capability:, payload:, context: {}, created_at:, version: 0)
          @id = RecordSupport.identifier(id, field: "id")
          @capability = RecordSupport.capability(capability)
          @payload = RecordSupport.document(payload, field: "payload")
          @context = RecordSupport.document(context, field: "context")
          @created_at = RecordSupport.time(created_at, field: "created_at")
          @version = RecordSupport.non_negative_integer(version, field: "version")
          freeze
        end
      end

      class Quote
        attr_reader :id,
                    :intent_id,
                    :provider_key,
                    :terms,
                    :private_state,
                    :expires_at,
                    :created_at,
                    :version

        def initialize(
          id:,
          intent_id:,
          provider_key:,
          terms:,
          private_state: {},
          expires_at: nil,
          created_at:,
          version: 0
        )
          @id = RecordSupport.identifier(id, field: "id")
          @intent_id = RecordSupport.identifier(intent_id, field: "intent_id")
          @provider_key = RecordSupport.identifier(provider_key, field: "provider_key")
          @terms = RecordSupport.document(terms, field: "terms")
          @private_state = RecordSupport.document(private_state, field: "private_state")
          @expires_at = RecordSupport.optional_time(expires_at, field: "expires_at")
          @created_at = RecordSupport.time(created_at, field: "created_at")
          @version = RecordSupport.non_negative_integer(version, field: "version")
          freeze
        end

        def expired?(at:)
          return false unless expires_at

          RecordSupport.time(at, field: "at") >= expires_at
        end
      end

      class Order
        STATUSES = %w[payment_pending accepted processing pending succeeded failed cancelled].freeze

        attr_reader :id,
                    :intent_id,
                    :quote_id,
                    :capability,
                    :provider_key,
                    :payload,
                    :context,
                    :terms,
                    :private_state,
                    :payment,
                    :status,
                    :attempts,
                    :progress,
                    :result,
                    :failure,
                    :created_at,
                    :updated_at,
                    :version

        def initialize(
          id:,
          intent_id:,
          quote_id:,
          capability:,
          provider_key:,
          payload:,
          context: {},
          terms:,
          private_state: {},
          payment: nil,
          status: "accepted",
          attempts: 0,
          progress: nil,
          result: nil,
          failure: nil,
          created_at:,
          updated_at: created_at,
          version: 0
        )
          raise ArgumentError, "status is invalid" unless STATUSES.include?(status)
          if status == "payment_pending" && payment.nil?
            raise ArgumentError, "payment-pending order requires payment details"
          end

          @id = RecordSupport.identifier(id, field: "id")
          @intent_id = RecordSupport.identifier(intent_id, field: "intent_id")
          @quote_id = RecordSupport.identifier(quote_id, field: "quote_id")
          @capability = RecordSupport.capability(capability)
          @provider_key = RecordSupport.identifier(provider_key, field: "provider_key")
          @payload = RecordSupport.document(payload, field: "payload")
          @context = RecordSupport.document(context, field: "context")
          @terms = RecordSupport.document(terms, field: "terms")
          @private_state = RecordSupport.document(private_state, field: "private_state")
          @payment = RecordSupport.optional_document(payment, field: "payment")
          @status = status.dup.freeze
          @attempts = RecordSupport.non_negative_integer(attempts, field: "attempts")
          @progress = RecordSupport.optional_document(progress, field: "progress")
          @result = RecordSupport.optional_document(result, field: "result")
          @failure = RecordSupport.optional_document(failure, field: "failure")
          @created_at = RecordSupport.time(created_at, field: "created_at")
          @updated_at = RecordSupport.time(updated_at, field: "updated_at")
          @version = RecordSupport.non_negative_integer(version, field: "version")
          freeze
        end
      end
    end
  end
end
