# frozen_string_literal: true

require "json"
require "rack/mock"
require "rack/utils"
require_relative "../core/contracts"

module ZeroXDA
  module Market
    module Payments
      class RackConfirmationClient
        def initialize(app:, token:)
          @client = Rack::MockRequest.new(app)
          @token = Core::RecordSupport.identifier(token.to_s, field: "operator token")
        end

        def confirm(order_id:, reference:, data: {})
          encoded_order_id = Rack::Utils.escape_path(order_id.to_s)
          response = @client.post(
            "/v1/market/orders/#{encoded_order_id}/payment/confirm",
            "HTTP_AUTHORIZATION" => "Bearer #{@token}",
            "CONTENT_TYPE" => "application/json",
            input: JSON.generate(reference: reference, data: data)
          )
          document = JSON.parse(response.body)
          return document.fetch("data") if response.status.between?(200, 299)

          error = document.fetch("errors", []).first || {}
          message = error.fetch("message", "payment confirmation failed")
          details = error.fetch("details", {})
          code = error.fetch("code", "payment_confirmation_failed")

          if response.status == 404
            raise Core::NotFound.new(details.fetch("resource", "marketplace_order"), order_id)
          end
          if response.status == 409
            raise Core::Conflict.new(message, code: code, details: details)
          end

          raise Core::ProviderContractError.new(
            message,
            details: details.merge("status" => response.status, "code" => code)
          )
        rescue JSON::ParserError => error
          raise Core::ProviderContractError.new(
            "payment confirmation returned invalid JSON",
            details: { message: error.message }
          )
        end
      end
    end
  end
end
