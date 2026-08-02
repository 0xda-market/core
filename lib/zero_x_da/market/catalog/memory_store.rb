# frozen_string_literal: true

require "monitor"
require_relative "../core/contracts"
require_relative "product"
require_relative "product_localization"

module ZeroXDA
  module Market
    module Catalog
      class MemoryStore
        DEFAULT_LOCALE = "en_US"

        def initialize(products: [], localizations: [])
          @products = products.to_h { |product| [product.sku, product] }
          @localizations = localizations.to_h do |localization|
            [[localization.product_sku, localization.locale], localization]
          end
          products.each do |product|
            key = [product.sku, product.locale]
            @localizations[key] ||= ProductLocalization.new(
              product_sku: product.sku,
              locale: product.locale,
              full_name: product.name,
              button_label: product.button_label,
              updated_by_user_id: product.updated_by_user_id,
              created_at: product.created_at,
              updated_at: product.updated_at
            )
          end
          @monitor = Monitor.new
        end

        # Defaults to the sellable catalog (marketable: true) to match the
        # legacy "list_products returns what you can sell" behavior. Pass
        # marketable: false for currencies, or nil for both.
        def list_products(status:, locale: DEFAULT_LOCALE, marketable: true)
          @monitor.synchronize do
            @products.values
                     .select { |product| status.nil? || product.status == status }
                     .select { |product| marketable.nil? || product.marketable? == marketable }
                     .sort_by { |product| [product.position, product.sku] }
                     .map { |product| localized_product(product, locale) }
          end
        end

        def find_product(sku, locale: DEFAULT_LOCALE)
          @monitor.synchronize do
            product = @products[sku.to_s]
            product && localized_product(product, locale)
          end
        end

        def list_localizations(sku)
          @monitor.synchronize do
            @localizations.values
                          .select { |localization| localization.product_sku == sku.to_s }
                          .sort_by(&:locale)
          end
        end

        def find_localization(sku, locale)
          @monitor.synchronize { @localizations[[sku.to_s, normalize_locale(locale)]] }
        end

        def replace_product(product, expected_version:)
          @monitor.synchronize do
            current = @products[product.sku]
            raise Core::NotFound.new("product", product.sku) unless current
            unless current.version == expected_version
              raise Core::ConcurrencyConflict.new("product", product.sku)
            end

            @products[product.sku] = product
            product
          end
        end

        def save_localization(localization, expected_version:)
          @monitor.synchronize do
            key = [localization.product_sku, localization.locale]
            current = @localizations[key]
            if expected_version.nil?
              if current
                raise Core::Conflict.new(
                  "product localization already exists",
                  code: "duplicate_localization",
                  details: { sku: localization.product_sku, locale: localization.locale }
                )
              end
            else
              raise Core::NotFound.new("product_localization", key.join(":")) unless current
              unless current.version == expected_version
                raise Core::ConcurrencyConflict.new("product_localization", key.join(":"))
              end
            end

            @localizations[key] = localization
            localization
          end
        end

        private

        def localized_product(product, locale)
          normalized = normalize_locale(locale)
          translation = @localizations[[product.sku, normalized]] ||
                        @localizations[[product.sku, DEFAULT_LOCALE]]
          if translation &&
             translation.locale == product.locale &&
             translation.full_name == product.name &&
             translation.button_label == product.button_label
            return product
          end

          Product.new(
            sku: product.sku,
            short_name: product.short_name,
            name: translation&.full_name || product.short_name,
            button_label: translation&.button_label || product.short_name,
            locale: translation&.locale || DEFAULT_LOCALE,
            metadata: product.metadata,
            status: product.status,
            position: product.position,
            marketable: product.marketable?,
            current_price_usdt: product.current_price_usdt,
            price_updated_at: product.price_updated_at,
            price_updated_by_user_id: product.price_updated_by_user_id,
            updated_by_user_id: product.updated_by_user_id,
            created_at: product.created_at,
            updated_at: product.updated_at,
            version: product.version
          )
        end

        def normalize_locale(value)
          normalized = value.to_s.strip.tr("-", "_")
          return DEFAULT_LOCALE if normalized.empty?
          return "uk_UA" if normalized.downcase.start_with?("uk")
          return "en_US" if normalized.downcase.start_with?("en")

          Product::LOCALE_PATTERN.match?(normalized) ? normalized : DEFAULT_LOCALE
        end
      end
    end
  end
end
