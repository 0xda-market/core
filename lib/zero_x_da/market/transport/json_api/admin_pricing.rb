# frozen_string_literal: true

module ZeroXDA
  module Market
    module Transport
      class JSONAPI
        module AdminPricingEndpoints
          def available?(endpoint)
            return !@pricing.nil? && !@admin_service.nil? if endpoint == :price_history

            super
          end

          def price_proposal(request)
            @admin_service.require_admin(user_id: request.params["actor_user_id"])
            locale = @request_parser.requested_locale(request)
            snapshot = @pricing.proposal_snapshot(locale: locale)
            entries = snapshot.fetch(:entries)
            json_response(
              200,
              {
                "data" => entries.map { |entry| present_price_proposal(entry) },
                "meta" => {
                  "count" => entries.length,
                  "base_currency" => Localization::Service::BASE_CURRENCY,
                  "locale" => locale,
                  "revision" => snapshot.fetch(:revision),
                  "generated_at" => timestamp(snapshot.fetch(:generated_at))
                }
              }
            )
          end

          def apply_prices(request)
            body = @request_parser.request_document(request)
            actor_user = @admin_service.require_admin(user_id: body.fetch("actor_user_id"))
            entries = body.fetch("prices")
            raise ArgumentError, "prices must be a non-empty array" unless entries.is_a?(Array)

            applied = @pricing.apply_prices(
              entries,
              source: "admin",
              set_by_user_id: actor_user.id,
              expected_revision: body.fetch("revision", @pricing.current_revision)
            )
            json_response(
              201,
              {
                "data" => applied.map { |price| present_price(price) },
                "meta" => {
                  "count" => applied.length,
                  "revision" => @pricing.current_revision,
                  "applied_at" => timestamp(applied.first&.created_at)
                }
              }
            )
          end

          def price_history(request)
            @admin_service.require_admin(user_id: request.params["actor_user_id"])
            limit = request.params.fetch("limit", 20)
            history = @pricing.history(limit: limit)
            json_response(
              200,
              {
                "data" => history.map { |price| present_price_history(price) },
                "meta" => {
                  "count" => history.length,
                  "revision" => @pricing.current_revision
                }
              }
            )
          end

          private

          def present_price_history(price)
            {
              "type" => "price_history",
              "id" => price.id.to_s,
              "attributes" => present_price(price).fetch("attributes")
            }
          end
        end

        EndpointHandler.prepend(AdminPricingEndpoints)
      end
    end
  end
end
