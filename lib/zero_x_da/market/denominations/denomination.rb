# frozen_string_literal: true

require_relative "../core/records"

module ZeroXDA
  module Market
    module Denominations
      # An issuer-owned, non-fiat unit of account. The market knows how to
      # present and price goods in it; balances stay with the issuer.
      class Denomination
        CODE_PATTERN = /\A[a-z][a-z0-9_]{1,31}\z/
        ISSUER_PATTERN = /\A[a-z0-9][a-z0-9._-]{0,63}\z/
        FAMILY_PATTERN = /\A[a-z0-9][a-z0-9_]{0,63}\z/
        STATUSES = %w[active inactive].freeze
        MAX_SCALE = 6

        attr_reader :code, :symbol, :scale, :issuer, :status, :product_families, :created_at

        def initialize(code:, symbol:, scale:, issuer:, product_families:, created_at:, status: "active")
          @code = pattern(code, CODE_PATTERN, field: "denomination code")
          unless symbol.is_a?(String) && symbol.length.between?(1, 16)
            raise ArgumentError, "denomination symbol must be 1 to 16 characters"
          end

          @symbol = symbol.dup.freeze
          @scale = Core::RecordSupport.non_negative_integer(scale, field: "scale")
          raise ArgumentError, "denomination scale is too large" if @scale > MAX_SCALE

          @issuer = pattern(issuer, ISSUER_PATTERN, field: "issuer")
          raise ArgumentError, "denomination status is invalid" unless STATUSES.include?(status)

          @status = status.dup.freeze
          raise ArgumentError, "product_families must be an array" unless product_families.is_a?(Array)

          @product_families = product_families.map { |family| pattern(family, FAMILY_PATTERN, field: "family") }
                                              .uniq.sort.freeze
          @created_at = Core::RecordSupport.time(created_at, field: "created_at")
          freeze
        end

        def active?
          @status == "active"
        end

        # Goods qualify only when their family is accepted by the issuer and
        # the product itself declares this denomination as a payment mode.
        def accepts?(product)
          metadata = product.metadata
          modes = metadata["payment_modes"]
          product.marketable? &&
            @product_families.include?(metadata["family"]) &&
            modes.is_a?(Array) && modes.include?(@code)
        end

        private

        def pattern(value, expression, field:)
          raise ArgumentError, "#{field} is invalid" unless value.is_a?(String) && expression.match?(value)

          value.dup.freeze
        end
      end
    end
  end
end
