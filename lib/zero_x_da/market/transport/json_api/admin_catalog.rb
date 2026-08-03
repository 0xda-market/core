# frozen_string_literal: true

module ZeroXDA
  module Market
    module Transport
      class JSONAPI
        module AdminCatalogEndpoints
          def available?(endpoint)
            return !@catalog.nil? && !@admin_service.nil? if endpoint == :admin_products

            super
          end

          def admin_products(request)
            @admin_service.require_admin(user_id: request.params["actor_user_id"])
            locale = @request_parser.requested_locale(request)
            products = @catalog.admin_products(locale: locale)
            json_response(
              200,
              {
                "data" => products.map { |product| present_admin_product(product) },
                "meta" => { "count" => products.length, "locale" => locale }
              }
            )
          end

          def create_admin_product(request)
            body = @request_parser.request_document(request)
            actor = @admin_service.require_admin(user_id: body.fetch("actor_user_id"))
            attributes = body.fetch("attributes")
            localization = body.fetch("localization")
            raise ArgumentError, "attributes must be an object" unless attributes.is_a?(Hash)
            raise ArgumentError, "localization must be an object" unless localization.is_a?(Hash)

            product = @catalog.create_product(
              sku: body.fetch("sku"),
              short_name: attributes.fetch("short_name"),
              status: attributes.fetch("status", "inactive"),
              position: attributes.fetch("position"),
              marketable: attributes.fetch("marketable", true),
              metadata: attributes.fetch("metadata", {}),
              locale: localization.fetch("locale", "en_US"),
              full_name: localization.fetch("full_name"),
              button_label: localization.fetch("button_label"),
              actor_user_id: actor.id
            )
            resource_response(201, present_admin_product(product))
          end

          def update_admin_product(request, sku:)
            body = @request_parser.request_document(request)
            actor = @admin_service.require_admin(user_id: body.fetch("actor_user_id"))
            product = @catalog.update_product(
              sku: sku,
              actor_user_id: actor.id,
              expected_version: body.fetch("version"),
              attributes: body.fetch("attributes")
            )
            resource_response(200, present_admin_product(product))
          end

          def save_admin_product_localization(request, sku:, locale:)
            body = @request_parser.request_document(request)
            actor = @admin_service.require_admin(user_id: body.fetch("actor_user_id"))
            created = body["version"].nil?
            localization = @catalog.save_localization(
              sku: sku,
              locale: locale,
              full_name: body.fetch("full_name"),
              button_label: body.fetch("button_label"),
              actor_user_id: actor.id,
              expected_version: body["version"]
            )
            resource_response(created ? 201 : 200, present_product_localization(localization))
          end

          private

          def present_admin_product(product)
            resource = present_product(product)
            resource.fetch("attributes").merge!(
              "marketable" => product.marketable?,
              "version" => product.version,
              "created_at" => timestamp(product.created_at),
              "updated_at" => timestamp(product.updated_at),
              "localizations" => @catalog.localizations(product.sku).map do |localization|
                present_product_localization(localization)
              end
            )
            resource
          end

          def present_product_localization(localization)
            {
              "type" => "product_localization",
              "id" => "#{localization.product_sku}:#{localization.locale}",
              "attributes" => {
                "product_sku" => localization.product_sku,
                "locale" => localization.locale,
                "full_name" => localization.full_name,
                "button_label" => localization.button_label,
                "updated_by_user_id" => localization.updated_by_user_id,
                "created_at" => timestamp(localization.created_at),
                "updated_at" => timestamp(localization.updated_at),
                "version" => localization.version
              }
            }
          end
        end

        module AdminCatalogRoutes
          private

          def resolve(request)
            method = request.request_method
            path = request.path_info

            if path == "/v1/admin/products" && available?(:admin_products)
              return route(:admin_products) if method == "GET"
              return route(:create_admin_product) if method == "POST"
            end

            product_match = path.match(%r{\A/v1/admin/products/([^/]+)\z})
            if method == "PATCH" && product_match && available?(:admin_products)
              return route(:update_admin_product, sku: product_match[1])
            end

            localization_match = path.match(
              %r{\A/v1/admin/products/([^/]+)/localizations/([^/]+)\z}
            )
            if method == "PUT" && localization_match && available?(:admin_products)
              return route(
                :save_admin_product_localization,
                sku: localization_match[1],
                locale: localization_match[2]
              )
            end

            super
          end
        end

        EndpointHandler.prepend(AdminCatalogEndpoints)
        Router.prepend(AdminCatalogRoutes)
      end
    end
  end
end
