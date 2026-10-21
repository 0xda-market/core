# frozen_string_literal: true

module ZeroXDA
  module Market
    module Transport
      class JSONAPI
        module DenominationEndpoints
          def initialize(denominations: nil, **options)
            @denominations = denominations
            super(**options)
          end

          def available?(endpoint)
            case endpoint
            when :denominations then !@denominations.nil?
            when :admin_denomination_prices then !@denominations.nil? && !@admin_service.nil?
            else super
            end
          end

          def denominations(_request)
            denominations = @denominations.denominations
            json_response(
              200,
              {
                "data" => denominations.map { |denomination| present_denomination(denomination) },
                "meta" => { "count" => denominations.length }
              }
            )
          end

          def denomination_prices(request, code:)
            locale = @request_parser.requested_locale(request)
            snapshot = @denominations.current_prices(denomination: code, locale: locale)
            denomination = snapshot.fetch(:denomination)
            entries = snapshot.fetch(:entries)
            json_response(
              200,
              {
                "data" => entries.map do |entry|
                  present_denomination_price(entry.fetch(:price), denomination, product: entry.fetch(:product))
                end,
                "meta" => {
                  "count" => entries.length,
                  "denomination" => denomination.code,
                  "symbol" => denomination.symbol,
                  "scale" => denomination.scale,
                  "locale" => locale
                }
              }
            )
          end

          def apply_denomination_prices(request)
            body = @request_parser.request_document(request)
            actor_user = @admin_service.require_admin(user_id: body.fetch("actor_user_id"))
            denomination = @denominations.find_denomination(body.fetch("denomination"))
            applied = @denominations.apply_prices(
              body.fetch("prices"),
              denomination: denomination.code,
              source: "admin",
              set_by_user_id: actor_user.id,
              expected_revision: body.fetch("revision", @denominations.current_revision)
            )
            json_response(
              201,
              {
                "data" => applied.map { |price| present_denomination_price(price, denomination) },
                "meta" => {
                  "count" => applied.length,
                  "revision" => @denominations.current_revision,
                  "applied_at" => timestamp(applied.first&.created_at)
                }
              }
            )
          end

          def denomination_price_history(request)
            @admin_service.require_admin(user_id: request.params["actor_user_id"])
            history = @denominations.history(limit: request.params.fetch("limit", 20))
            scales = @denominations.denominations.to_h { |denomination| [denomination.code, denomination] }
            json_response(
              200,
              {
                "data" => history.map do |price|
                  resource = present_denomination_price(price, scales[price.denomination])
                  resource.merge("type" => "denomination_price_history", "id" => price.id.to_s)
                end,
                "meta" => {
                  "count" => history.length,
                  "revision" => @denominations.current_revision
                }
              }
            )
          end

          private

          def present_denomination(denomination)
            {
              "type" => "denomination",
              "id" => denomination.code,
              "attributes" => {
                "code" => denomination.code,
                "symbol" => denomination.symbol,
                "scale" => denomination.scale,
                "issuer" => denomination.issuer,
                "product_families" => denomination.product_families
              }
            }
          end

          # An inactive denomination in history keeps its integer amount but has
          # no presentable scale or symbol.
          def present_denomination_price(price, denomination, product: nil)
            attributes = {
              "sku" => price.sku,
              "denomination" => price.denomination,
              "amount_minor" => price.amount_minor,
              "amount" => denomination && price.amount_string(denomination.scale),
              "symbol" => denomination&.symbol,
              "source" => price.source,
              "edited_by_user_id" => price.set_by_user_id,
              "applied_at" => timestamp(price.created_at)
            }
            attributes["name"] = product.name if product
            { "type" => "denomination_price", "id" => price.sku, "attributes" => attributes }
          end
        end

        EndpointHandler.prepend(DenominationEndpoints)
      end
    end
  end
end
