# frozen_string_literal: true

require "sequel"
require_relative "../core/contracts"
require_relative "product"
require_relative "product_localization"

module ZeroXDA
  module Market
    module Catalog
      class PostgresStore
        DEFAULT_LOCALE = "en_US"
        LANGUAGE_FALLBACKS = {
          "en" => "en_US",
          "uk" => "uk_UA",
          "ru" => "ru_RU",
          "es" => "es_ES",
          "pt" => "pt_BR"
        }.freeze

        def initialize(database:)
          @database = database.connection
          @products = @database[Sequel.qualify(:market, :products)]
          @localizations = @database[
            Sequel.qualify(:market, :product_localizations)
          ]
        end

        # Defaults to the sellable catalog (marketable: true) to match the
        # legacy "list_products returns what you can sell" behavior. Pass
        # marketable: false for currencies, or nil for both. Pass status: nil
        # for the complete administrator catalog.
        def list_products(status:, locale: DEFAULT_LOCALE, marketable: true)
          locale = normalize_locale(locale)
          scope = @products
          scope = scope.where(status: status) unless status.nil?
          scope = scope.where(marketable: marketable) unless marketable.nil?
          rows = scope.order(:position, :sku).all
          translations = translations_for(rows.map { |row| row.fetch(:sku) }, locale)
          rows.map do |row|
            deserialize(row, locale: locale, translation: translations.fetch(row.fetch(:sku)))
          end
        end

        def find_product(sku, locale: DEFAULT_LOCALE)
          locale = normalize_locale(locale)
          row = @products.where(sku: sku.to_s).first
          return nil unless row

          translation = translations_for([row.fetch(:sku)], locale).fetch(row.fetch(:sku))
          deserialize(row, locale: locale, translation: translation)
        end

        def list_localizations(sku)
          @localizations.where(product_sku: sku.to_s)
                        .order(:locale)
                        .all
                        .map { |row| deserialize_localization(row) }
        end

        def find_localization(sku, locale)
          row = @localizations.where(
            product_sku: sku.to_s,
            locale: normalize_locale(locale)
          ).first
          row && deserialize_localization(row)
        end

        def insert_product(product, localization:)
          @database.transaction do
            @products.insert(serialize_product(product))
            @localizations.insert(serialize_localization(localization))
          end
          find_product(product.sku, locale: localization.locale)
        rescue Sequel::UniqueConstraintViolation
          raise Core::Conflict.new(
            "product already exists",
            code: "duplicate_product",
            details: { sku: product.sku }
          )
        end

        def replace_product(product, expected_version:)
          count = @products.where(sku: product.sku, version: expected_version).update(
            short_name: product.short_name,
            metadata: Sequel.pg_jsonb(product.metadata),
            status: product.status,
            position: product.position,
            marketable: product.marketable?,
            updated_by_user_id: product.updated_by_user_id,
            updated_at: product.updated_at,
            version: product.version
          )
          return find_product(product.sku, locale: product.locale) if count == 1

          raise Core::NotFound.new("product", product.sku) unless @products.where(sku: product.sku).get(:sku)

          raise Core::ConcurrencyConflict.new("product", product.sku)
        end

        def save_localization(localization, expected_version:)
          if expected_version.nil?
            @localizations.insert(serialize_localization(localization))
            return localization
          end

          count = @localizations.where(
            product_sku: localization.product_sku,
            locale: localization.locale,
            version: expected_version
          ).update(serialize_localization(localization))
          return localization if count == 1

          key = "#{localization.product_sku}:#{localization.locale}"
          exists = @localizations.where(
            product_sku: localization.product_sku,
            locale: localization.locale
          ).get(:product_sku)
          raise Core::NotFound.new("product_localization", key) unless exists

          raise Core::ConcurrencyConflict.new("product_localization", key)
        rescue Sequel::UniqueConstraintViolation
          raise Core::Conflict.new(
            "product localization already exists",
            code: "duplicate_localization",
            details: { sku: localization.product_sku, locale: localization.locale }
          )
        end

        private

        def translations_for(skus, locale)
          language_fallback = language_fallback_for(locale)
          locales = [locale, language_fallback, DEFAULT_LOCALE].compact.uniq
          rows = @localizations.where(product_sku: skus, locale: locales).all
          grouped = rows.group_by { |row| row.fetch(:product_sku) }
          skus.to_h do |sku|
            candidates = grouped.fetch(sku, [])
            requested = candidates.find { |row| row.fetch(:locale) == locale }
            language = candidates.find { |row| row.fetch(:locale) == language_fallback }
            fallback = candidates.find { |row| row.fetch(:locale) == DEFAULT_LOCALE }
            [sku, requested || language || fallback || {}]
          end
        end

        def serialize_product(product)
          {
            sku: product.sku,
            short_name: product.short_name,
            metadata: Sequel.pg_jsonb(product.metadata),
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
          }
        end

        def deserialize(row, locale:, translation:)
          short_name = row.fetch(:short_name)
          Product.new(
            sku: row.fetch(:sku),
            short_name: short_name,
            name: translation.fetch(:full_name, short_name),
            button_label: translation.fetch(:button_label, short_name),
            locale: translation.fetch(:locale, DEFAULT_LOCALE),
            metadata: document(row.fetch(:metadata)),
            status: row.fetch(:status),
            position: row.fetch(:position),
            marketable: row.fetch(:marketable, true),
            current_price_usdt: row.fetch(:current_price_usdt),
            price_updated_at: row.fetch(:price_updated_at),
            price_updated_by_user_id: row.fetch(:price_updated_by_user_id)&.to_s,
            updated_by_user_id: row.fetch(:updated_by_user_id)&.to_s,
            created_at: row.fetch(:created_at),
            updated_at: row.fetch(:updated_at),
            version: row.fetch(:version)
          )
        end

        def serialize_localization(localization)
          {
            product_sku: localization.product_sku,
            locale: localization.locale,
            full_name: localization.full_name,
            button_label: localization.button_label,
            updated_by_user_id: localization.updated_by_user_id,
            created_at: localization.created_at,
            updated_at: localization.updated_at,
            version: localization.version
          }
        end

        def deserialize_localization(row)
          ProductLocalization.new(
            product_sku: row.fetch(:product_sku),
            locale: row.fetch(:locale),
            full_name: row.fetch(:full_name),
            button_label: row.fetch(:button_label),
            updated_by_user_id: row.fetch(:updated_by_user_id)&.to_s,
            created_at: row.fetch(:created_at),
            updated_at: row.fetch(:updated_at),
            version: row.fetch(:version)
          )
        end

        def normalize_locale(value)
          normalized = value.to_s.strip.tr("-", "_")
          return DEFAULT_LOCALE if normalized.empty?

          if normalized.match?(/\A[a-zA-Z]{2}\z/)
            return LANGUAGE_FALLBACKS.fetch(normalized.downcase, DEFAULT_LOCALE)
          end

          parts = normalized.split("_", 2)
          candidate = parts.length == 2 ? "#{parts[0].downcase}_#{parts[1].upcase}" : normalized
          Product::LOCALE_PATTERN.match?(candidate) ? candidate : DEFAULT_LOCALE
        end

        def language_fallback_for(locale)
          LANGUAGE_FALLBACKS[locale.to_s[0, 2].downcase]
        end

        def document(value)
          value.respond_to?(:to_hash) ? value.to_hash : value
        end
      end
    end
  end
end
