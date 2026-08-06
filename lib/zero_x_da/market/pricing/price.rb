# frozen_string_literal: true

require "bigdecimal"
require_relative "../core/records"

module ZeroXDA
  module Market
    module Pricing
      class Price
        SOURCES = %w[admin core].freeze
        FX_SOURCE_PATTERN = /\Afx:[a-z0-9][a-z0-9._-]{0,63}\z/
        MAX_AMOUNT = BigDecimal("1000000000")

        attr_reader :id,
                    :sku,
                    :amount_usdt,
                    :source,
                    :set_by_user_id,
                    :created_at

        def initialize(
          sku:,
          amount_usdt:,
          source:,
          created_at:,
          set_by_user_id: nil,
          id: nil
        )
          @id = normalize_id(id)
          @sku = non_empty_string(sku, field: "sku")
          @amount_usdt = decimal(amount_usdt)
          unless SOURCES.include?(source) || FX_SOURCE_PATTERN.match?(source.to_s)
            raise ArgumentError, "price source is invalid"
          end

          @source = source.dup.freeze
          @set_by_user_id = optional_string(
            set_by_user_id,
            field: "set_by_user_id"
          )
          @created_at = Core::RecordSupport.time(created_at, field: "created_at")
          freeze
        end

        private

        def normalize_id(value)
          return nil if value.nil?

          integer = Integer(value)
          raise ArgumentError, "price id must be positive" unless integer.positive?

          integer
        rescue ArgumentError, TypeError
          raise ArgumentError, "price id must be a positive integer"
        end

        def decimal(value)
          amount = case value
                   when BigDecimal then value
                   when Integer then BigDecimal(value)
                   when String then parse_decimal(value)
                   when Numeric then BigDecimal(value.to_s)
                   else raise ArgumentError, "amount_usdt must be a number"
                   end
          unless amount.finite? && amount.positive?
            raise ArgumentError, "amount_usdt must be positive"
          end
          raise ArgumentError, "amount_usdt is too large" if amount > MAX_AMOUNT

          amount.round(12)
        end

        def parse_decimal(value)
          BigDecimal(value)
        rescue ArgumentError
          raise ArgumentError, "amount_usdt must be a number"
        end

        def non_empty_string(value, field:)
          unless value.is_a?(String) && !value.empty?
            raise ArgumentError, "#{field} must be a non-empty string"
          end

          value.dup.freeze
        end

        def optional_string(value, field:)
          return nil if value.nil?

          string = value.to_s
          raise ArgumentError, "#{field} is too long" if string.bytesize > 128

          string.empty? ? nil : string.freeze
        end
      end
    end
  end
end
