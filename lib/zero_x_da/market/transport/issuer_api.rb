# frozen_string_literal: true

require "rack"
require_relative "bearer_auth"
require_relative "issuer_order_presenter"
require_relative "json_api/error_mapper"
require_relative "json_api/request_parser"
require_relative "json_api/response"

module ZeroXDA
  module Market
    module Transport
      # Issuer side of issuer orders. One token is bound to one issuer, which
      # sees only its own orders. The issuer claims an order, performs its own
      # atomic debit and grant, then reports the outcome.
      class IssuerAPI
        include JSONAPI::Response
        include IssuerOrderPresenter

        ORDER_PATH = %r{\A/v1/orders/([^/]+)(?:/(claim|fulfil|reject))?\z}

        def initialize(issuer_orders:, issuer:, token:)
          @issuer_orders = issuer_orders
          @issuer = Core::RecordSupport.identifier(issuer, field: "issuer")
          @authentication = BearerAuth.new(token: token)
          @error_mapper = JSONAPI::ErrorMapper.new
          @request_parser = JSONAPI::RequestParser.new
        end

        def call(environment)
          request = Rack::Request.new(environment)
          @error_mapper.call do
            next @error_mapper.unauthorized unless @authentication.authorized?(request)

            route(request)
          end
        end

        private

        def route(request)
          method = request.request_method
          if method == "GET" && request.path_info == "/v1/orders"
            orders = @issuer_orders.queue(issuer: @issuer, status: request.params.fetch("status", "pending"),
                                          limit: request.params.fetch("limit", 50))
            return json_response(200, { "data" => orders.map { |order| present_issuer_order(order) },
                                        "meta" => { "count" => orders.length, "issuer" => @issuer } })
          end

          if request.path_info == "/v1/account-links"
            return account_link(request) if %w[PUT DELETE].include?(method)

            return not_found
          end

          match = ORDER_PATH.match(request.path_info)
          return not_found unless match

          id, action = match.captures
          return resource_response(200, present_issuer_order(@issuer_orders.find_for_issuer(id, issuer: @issuer))) if method == "GET" && action.nil?
          return not_found unless method == "POST" && action

          resource_response(200, present_issuer_order(transition(id, action, request)))
        end

        def transition(id, action, request)
          case action
          when "claim"
            @request_parser.ensure_empty_or_object_body(request)
            @issuer_orders.claim(id, issuer: @issuer)
          when "fulfil"
            body = @request_parser.request_document(request)
            @issuer_orders.fulfil(
              id, issuer: @issuer, reference: body.fetch("issuer_reference"), amount_minor: body.fetch("amount_minor"),
                  denomination: body.fetch("denomination"), recipient_subject: body.fetch("recipient_subject")
            )
          when "reject"
            body = @request_parser.request_document(request)
            @issuer_orders.reject(id, issuer: @issuer, code: body.fetch("code"))
          end
        end

        # The issuer publishes and withdraws its own channel-account bindings.
        def account_link(request)
          if request.request_method == "PUT"
            body = @request_parser.request_document(request)
            link = @issuer_orders.link_account(
              issuer: @issuer, provider: body.fetch("provider"), provider_user_id: body.fetch("provider_user_id"),
              subject: body.fetch("subject"), pub_dress: body.fetch("pub_dress")
            )
            return resource_response(200, present_account_link(link))
          end

          removed = @issuer_orders.unlink_account(issuer: @issuer, provider: request.params.fetch("provider"),
                                                  provider_user_id: request.params.fetch("provider_user_id"))
          json_response(200, { "meta" => { "removed" => removed } })
        end

        def not_found
          json_response(404, { "errors" => [{ "code" => "route_not_found", "message" => "route was not found" }] })
        end
      end
    end
  end
end
