# frozen_string_literal: true

require_relative "../core/contracts"
require_relative "product"
require_relative "product_localization"

module ZeroXDA
  module Market
    module Catalog
      class Service
        DEFAULT_LOCALE = "en_US"

        def initialize(store:, clock: -> { Time.now.utc })
          @store = store
          @clock = clock
        end

        # The sellable catalog: currencies (marketable: false) are excluded.
        def products(locale: DEFAULT_LOCALE)
          @store.list_products(status: "active", locale: locale, marketable: true)
        end

        # Currency products; their current price is the exchange rate.
        def currencies(locale: DEFAULT_LOCALE)
          @store.list_products(status: "active", locale: locale, marketable: false)
        end

        # The complete catalog for administrator workflows. Inactive and
        # non-marketable rows stay visible so they can be repaired or restored.
        def admin_products(locale: DEFAULT_LOCALE)
          @store.list_products(status: nil, locale: locale, marketable: nil)
        end

        # Resolves any product, marketable or not, so pricing flows
        # (/apply_price uah 41.50) work for currencies too.
        def find_product(sku, locale: DEFAULT_LOCALE)
          @store.find_product(sku.to_s, locale: locale) || raise(Core::NotFound.new("product", sku))
        end

        def localizations(sku)
          find_product(sku)
          @store.list_localizations(sku.to_s)
        end

        def create_product(
          sku:,
          short_name:,
          full_name:,
          button_label:,
          locale: DEFAULT_LOCALE,
          actor_user_id:,
          position:,
          metadata: {},
          status: "inactive",
          marketable: true
        )
          normalized_locale = normalize_locale(locale)
          now = @clock.call
          product = Product.new(
            sku: sku,
            short_name: short_name,
            name: full_name,
            button_label: button_label,
            locale: normalized_locale,
            metadata: metadata,
            status: status,
            position: position,
            marketable: marketable,
            updated_by_user_id: actor_user_id,
            created_at: now
          )
          localization = ProductLocalization.new(
            product_sku: product.sku,
            locale: normalized_locale,
            full_name: full_name,
            button_label: button_label,
            updated_by_user_id: actor_user_id,
            created_at: now
          )
          @store.insert_product(product, localization: localization)
        end

        def update_product(sku:, actor_user_id:, expected_version:, attributes:)
          raise ArgumentError, "attributes must be an object" unless attributes.is_a?(Hash)

          current = find_product(sku, locale: DEFAULT_LOCALE)
          expected_version = Integer(expected_version)
          updated = Product.new(
            sku: current.sku,
            short_name: attributes.fetch("short_name", current.short_name),
            name: current.name,
            button_label: current.button_label,
            locale: current.locale,
            metadata: attributes.fetch("metadata", current.metadata),
            status: attributes.fetch("status", current.status),
            position: attributes.fetch("position", current.position),
            marketable: attributes.key?("marketable") ? attributes.fetch("marketable") : current.marketable?,
            current_price_usdt: current.current_price_usdt,
            price_updated_at: current.price_updated_at,
            price_updated_by_user_id: current.price_updated_by_user_id,
            updated_by_user_id: actor_user_id,
            created_at: current.created_at,
            updated_at: @clock.call,
            version: current.version + 1
          )
          @store.replace_product(updated, expected_version: expected_version)
        end

        def save_localization(
          sku:,
          locale:,
          full_name:,
          button_label:,
          actor_user_id:,
          expected_version: nil
        )
          product = find_product(sku)
          normalized_locale = normalize_locale(locale)
          existing = @store.find_localization(product.sku, normalized_locale)
          if existing
            raise ArgumentError, "version is required" if expected_version.nil?

            expected_version = Integer(expected_version)
          elsif !expected_version.nil?
            raise ArgumentError, "version must be omitted for a new localization"
          end

          localization = ProductLocalization.new(
            product_sku: product.sku,
            locale: normalized_locale,
            full_name: full_name,
            button_label: button_label,
            updated_by_user_id: actor_user_id,
            created_at: existing&.created_at || @clock.call,
            updated_at: @clock.call,
            version: existing ? existing.version + 1 : 0
          )
          @store.save_localization(localization, expected_version: expected_version)
        end

        private

        def normalize_locale(value)
          normalized = value.to_s.strip.tr("-", "_")
          raise ArgumentError, "locale is invalid" unless Product::LOCALE_PATTERN.match?(normalized)

          normalized
        end
      end
    end
  end
end
