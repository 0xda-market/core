# frozen_string_literal: true

require_relative "../core/records"

module ZeroXDA
  module Market
    module Denominations
      class Price
        SOURCES = %w[admin core].freeze
        MAX_AMOUNT_MINOR = 1_000_000_000_000

        attr_reader :id, :sku, :denomination, :amount_minor, :source, :set_by_user_id, :created_at

        def initialize(sku:, denomination:, amount_minor:, source:, created_at:, set_by_user_id: nil, id: nil)
          @id = id.nil? ? nil : positive_integer(id, field: "denomination price id")
          @sku = non_empty_string(sku, field: "sku")
          @denomination = non_empty_string(denomination, field: "denomination")
          @amount_minor = positive_integer(amount_minor, field: "amount_minor")
          raise ArgumentError, "amount_minor is too large" if @amount_minor > MAX_AMOUNT_MINOR
          raise ArgumentError, "denomination price source is invalid" unless SOURCES.include?(source)

          @source = source.dup.freeze
          @set_by_user_id = set_by_user_id.nil? ? nil : non_empty_string(set_by_user_id.to_s, field: "set_by_user_id")
          @created_at = Core::RecordSupport.time(created_at, field: "created_at")
          freeze
        end

        # The exact amount in whole denomination units, e.g. "400" at scale 0
        # or "4.00" for 400 minor units at scale 2.
        def amount_string(scale)
          return @amount_minor.to_s if scale.zero?

          digits = @amount_minor.to_s.rjust(scale + 1, "0")
          "#{digits[0...-scale]}.#{digits[-scale..]}"
        end

        private

        # Integer-only: a fractional amount is rejected, never rounded.
        def positive_integer(value, field:)
          integer = value.is_a?(String) ? Integer(value, 10) : value
          raise ArgumentError unless integer.is_a?(Integer) && integer.positive?

          integer
        rescue ArgumentError, TypeError
          raise ArgumentError, "#{field} must be a positive integer"
        end

        def non_empty_string(value, field:)
          raise ArgumentError, "#{field} must be a non-empty string" unless value.is_a?(String) && !value.empty?
          raise ArgumentError, "#{field} is too long" if value.bytesize > 128

          value.dup.freeze
        end
      end
    end
  end
end
