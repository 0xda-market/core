# frozen_string_literal: true

require_relative "endpoint_handler"
require_relative "router"

module ZeroXDA
  module Market
    module Transport
      class JSONAPI
        module BrokerEarningEndpoints
          def initialize(broker_earnings: nil, **options)
            @broker_earnings = broker_earnings
            super(**options)
          end

          def available?(endpoint)
            return !@broker_earnings.nil? if endpoint == :broker_earnings
            super
          end

          def broker_earnings(request)
            actor = request.params.fetch("actor_user_id")
            earnings = @broker_earnings.list(actor_user_id: actor)
            json_response(200, { "data" => earnings.map { |earning| present_earning(earning) },
                                 "meta" => { "count" => earnings.length } })
          end

          def broker_balance(request)
            balance = @broker_earnings.balance(actor_user_id: request.params.fetch("actor_user_id"))
            json_response(200, { "data" => { "type" => "broker_balance", "id" => "current",
                                               "attributes" => present_balance(balance) } })
          end

          def broker_payout_profile(request)
            actor = request.params.fetch("actor_user_id")
            profile = @broker_earnings.payout_profile(actor_user_id: actor)
            return json_response(200, { "data" => nil }) unless profile
            json_response(200, { "data" => present_profile(profile) })
          end

          def save_broker_payout_profile(request)
            body = @request_parser.request_document(request)
            profile = @broker_earnings.save_payout_profile(
              actor_user_id: body.fetch("actor_user_id"), network: body.fetch("network"),
              destination: body.fetch("destination"), minimum_payout_amount: body.fetch("minimum_payout_amount", "0"),
              enabled: body.fetch("enabled", true), expected_version: body["version"]
            )
            resource_response(200, present_profile(profile))
          end

          def broker_payouts(request)
            payouts = @broker_earnings.list_payouts(actor_user_id: request.params.fetch("actor_user_id"))
            json_response(200, { "data" => payouts.map { |payout| present_payout(payout) },
                                 "meta" => { "count" => payouts.length } })
          end

          def queue_broker_payout(request)
            body = @request_parser.request_document(request)
            payout = @broker_earnings.queue_payout(actor_user_id: body.fetch("actor_user_id"),
                                                    idempotency_key: body["idempotency_key"])
            resource_response(201, present_payout(payout))
          end

          private

          def present_earning(earning)
            { "type" => "broker_earning", "id" => earning.id,
              "attributes" => { "order_id" => earning.order_id, "quantity" => decimal_string(earning.quantity),
                                  "ask_amount" => decimal_string(earning.ask_amount), "ask_currency" => earning.ask_currency,
                                  "payable_amount" => decimal_string(earning.payable_amount),
                                  "payable_currency" => earning.payable_currency, "status" => earning.state,
                                  "payout_id" => earning.payout_id, "available_at" => timestamp(earning.available_at),
                                  "paid_at" => timestamp(earning.paid_at), "updated_at" => timestamp(earning.updated_at) }.compact }
          end

          def present_balance(balance)
            { "pending" => decimal_string(balance.pending), "available" => decimal_string(balance.available),
              "payout_queued" => decimal_string(balance.payout_queued), "paid" => decimal_string(balance.paid),
              "currency" => balance.currency }
          end

          def present_profile(profile)
            { "type" => "broker_payout_profile", "id" => profile.seller_user_id,
              "attributes" => { "currency" => profile.currency, "network" => profile.network,
                                  "destination" => profile.destination,
                                  "minimum_payout_amount" => decimal_string(profile.minimum_payout_amount),
                                  "enabled" => profile.enabled, "updated_at" => timestamp(profile.updated_at),
                                  "version" => profile.version } }
          end

          def present_payout(payout)
            { "type" => "broker_payout", "id" => payout.id,
              "attributes" => { "amount" => decimal_string(payout.amount), "currency" => payout.currency,
                                  "network" => payout.network, "destination" => payout.destination,
                                  "status" => payout.state, "external_reference" => payout.external_reference,
                                  "created_at" => timestamp(payout.created_at), "paid_at" => timestamp(payout.paid_at),
                                  "version" => payout.version }.compact }
          end
        end

        module BrokerEarningRoutes
          private

          def resolve(request)
            method = request.request_method
            path = request.path_info
            return route(:broker_earnings) if method == "GET" && path == "/v1/broker/earnings" && available?(:broker_earnings)
            return route(:broker_balance) if method == "GET" && path == "/v1/broker/balance" && available?(:broker_earnings)
            return route(:broker_payout_profile) if method == "GET" && path == "/v1/broker/payout-profile" && available?(:broker_earnings)
            return route(:save_broker_payout_profile) if method == "PUT" && path == "/v1/broker/payout-profile" && available?(:broker_earnings)
            return route(:broker_payouts) if method == "GET" && path == "/v1/broker/payouts" && available?(:broker_earnings)
            return route(:queue_broker_payout) if method == "POST" && path == "/v1/broker/payouts/queue" && available?(:broker_earnings)
            super
          end
        end

        EndpointHandler.prepend(BrokerEarningEndpoints)
        Router.prepend(BrokerEarningRoutes)
      end
    end
  end
end
