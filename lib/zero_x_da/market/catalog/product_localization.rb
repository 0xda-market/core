# frozen_string_literal: true

require_relative "../core/records"
require_relative "product"

module ZeroXDA
  module Market
    module Catalog
      class ProductLocalization
        attr_reader :product_sku,
                    :locale,
                    :full_name,
                    :button_label,
                    :updated_by_user_id,
                    :created_at,
                    :updated_at,
                    :version

        def initialize(
          product_sku:,
          locale:,
          full_name:,
          button_label:,
          updated_by_user_id: nil,
          created_at:,
          updated_at: created_at,
          version: 0
        )
          @product_sku = string(product_sku, field: "product_sku", maximum_length: 60)
          raise ArgumentError, "product_sku is invalid" unless Product::SKU_PATTERN.match?(@product_sku)

          @locale = string(locale, field: "locale", maximum_length: 16).tr("-", "_").freeze
          raise ArgumentError, "locale is invalid" unless Product::LOCALE_PATTERN.match?(@locale)

          @full_name = string(full_name, field: "full_name", maximum_length: 160)
          @button_label = string(button_label, field: "button_label", maximum_length: 64)
          @updated_by_user_id = updated_by_user_id && Core::RecordSupport.identifier(
            updated_by_user_id,
            field: "updated_by_user_id"
          )
          @created_at = Core::RecordSupport.time(created_at, field: "created_at")
          @updated_at = Core::RecordSupport.time(updated_at, field: "updated_at")
          @version = Core::RecordSupport.non_negative_integer(version, field: "version")
          freeze
        end

        private

        def string(value, field:, maximum_length:)
          unless value.is_a?(String) && !value.empty?
            raise ArgumentError, "#{field} must be a non-empty string"
          end

          encoded = value.encode(Encoding::UTF_8)
          raise ArgumentError, "#{field} is too long" if encoded.length > maximum_length

          encoded.freeze
        rescue EncodingError
          raise ArgumentError, "#{field} contains invalid UTF-8"
        end
      end
    end
  end
end
