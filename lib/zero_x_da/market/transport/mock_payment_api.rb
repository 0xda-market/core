# frozen_string_literal: true

require "json"
require "rack"
require "time"
require_relative "../core/contracts"
require_relative "bearer_auth"

module ZeroXDA
  module Market
    module Transport
      class MockPaymentAPI
        MAX_BODY_BYTES = 1_048_576
        JSON_HEADERS = {
          "content-type" => "application/json; charset=utf-8",
          "cache-control" => "no-store"
        }.freeze

        def initialize(provider:, token:)
          @provider = provider
          @authentication = BearerAuth.new(token: token)
        end

        def call(environment)
          request = Rack::Request.new(environment)
          unless @authentication.authorized?(request)
            return error_response(401, "unauthorized", "mock payment authentication failed")
          end

          route(request)
        rescue JSON::ParserError
          error_response(400, "invalid_json", "request body is not valid JSON")
        rescue KeyError => error
          error_response(
            400,
            "missing_field",
            "request is missing a required field",
            { "field" => error.key.to_s }
          )
        rescue Core::NotFound => error
          core_error_response(404, error)
        rescue Core::Conflict => error
          core_error_response(409, error)
        rescue ArgumentError => error
          error_response(422, "validation_error", error.message)
        rescue StandardError
          error_response(500, "internal_error", "the mock provider could not process the request")
        end

        private

        def route(request)
          method = request.request_method
          path = request.path_info

          if method == "POST" && path == "/v1/payment-intents"
            body = request_document(request)
            intent = @provider.create_intent(order_id: body.fetch("order_id"))
            return resource_response(201, intent)
          end

          if (match = path.match(%r{\A/v1/payment-intents/([^/]+)\z}))
            return resource_response(200, @provider.fetch_intent(match[1])) if method == "GET"
          end

          if (match = path.match(%r{\A/v1/payment-intents/([^/]+)/succeed\z}))
            if method == "POST"
              body = request_document(request)
              intent = @provider.succeed(
                match[1],
                reference: body["reference"],
                data: body.fetch("data", {})
              )
              return resource_response(200, intent)
            end
          end

          if (match = path.match(%r{\A/v1/payment-intents/([^/]+)/fail\z}))
            if method == "POST"
              body = request_document(request)
              intent = @provider.fail(
                match[1],
                code: body.fetch("code", "mock_payment_failed"),
                message: body.fetch("message", "mock payment failed"),
                details: body.fetch("details", {})
              )
              return resource_response(200, intent)
            end
          end

          if (match = path.match(%r{\A/v1/payment-intents/([^/]+)/expire\z}))
            if method == "POST"
              request_document(request)
              return resource_response(200, @provider.expire(match[1]))
            end
          end

          error_response(404, "route_not_found", "route was not found")
        end

        def request_document(request)
          media_type = request.media_type
          unless media_type == "application/json" || media_type&.end_with?("+json")
            raise ArgumentError, "content type must be application/json"
          end

          raw = request.body.read(MAX_BODY_BYTES + 1)
          raise ArgumentError, "request body is too large" if raw.bytesize > MAX_BODY_BYTES

          raw = "{}" if raw.empty?
          Core::RecordSupport.document(JSON.parse(raw), field: "request")
        end

        def present_intent(intent)
          {
            "type" => "mock_payment_intent",
            "id" => intent.id,
            "attributes" => {
              "order_id" => intent.order_id,
              "amount" => intent.amount,
              "currency" => intent.currency,
              "expires_at" => timestamp(intent.expires_at),
              "status" => intent.status,
              "reference" => intent.reference,
              "data" => intent.data,
              "confirmation" => intent.confirmation,
              "failure" => intent.failure,
              "created_at" => timestamp(intent.created_at),
              "updated_at" => timestamp(intent.updated_at)
            }
          }
        end

        def resource_response(status, intent)
          json_response(status, { "data" => present_intent(intent) })
        end

        def timestamp(value)
          value&.iso8601(6)
        end

        def core_error_response(status, error)
          error_response(status, error.code, error.message, error.details)
        end

        def error_response(status, code, message, details = {})
          json_response(
            status,
            {
              "errors" => [
                {
                  "code" => code,
                  "message" => message,
                  "details" => details
                }
              ]
            }
          )
        end

        def json_response(status, document)
          [status, JSON_HEADERS, [JSON.generate(document)]]
        end
      end
    end
  end
end
