# frozen_string_literal: true

require_relative "../core/contracts"
require_relative "denomination"
require_relative "price"

module ZeroXDA
  module Market
    module Denominations
      # Prices goods in issuer-owned denominations. This service never values a
      # denomination in USDT or fiat, and never reads or moves balances.
      class Service
        DEFAULT_LOCALE = "en_US"

        def initialize(store:, catalog:, clock: -> { Time.now.utc })
          @store = store
          @catalog = catalog
          @clock = clock
        end

        def denominations
          @store.list_denominations.select(&:active?)
        end

        def find_denomination(code)
          denomination = @store.find_denomination(code)
          raise Core::NotFound.new("denomination", code) unless denomination&.active?

          denomination
        end

        # Current prices for the sellable catalog only: inactive or
        # non-marketable products and their staged prices stay hidden.
        def current_prices(denomination:, locale: DEFAULT_LOCALE)
          resolved = find_denomination(denomination)
          prices = @store.latest_prices(denomination: resolved.code)
          entries = @catalog.products(locale: locale).filter_map do |product|
            price = prices[product.sku]
            { product: product, price: price } if price && resolved.accepts?(product)
          end
          { denomination: resolved, entries: entries.freeze }.freeze
        end

        # Validates every entry before acquiring the store revision lock, so a
        # bulk application either appends every price or none.
        def apply_prices(entries, denomination:, source: "admin", set_by_user_id: nil, expected_revision: nil)
          raise ArgumentError, "prices must be a non-empty array" unless entries.is_a?(Array) && !entries.empty?

          resolved = find_denomination(denomination)
          now = current_time
          prices = entries.map do |entry|
            raise ArgumentError, "price entry must be an object" unless entry.respond_to?(:to_h)

            entry = entry.to_h.transform_keys(&:to_s)
            product = @catalog.find_product(entry.fetch("sku"))
            unless resolved.accepts?(product)
              raise ArgumentError, "product #{product.sku} is not eligible for denomination #{resolved.code}"
            end

            Price.new(
              sku: product.sku,
              denomination: resolved.code,
              amount_minor: entry.fetch("amount_minor"),
              source: source,
              set_by_user_id: set_by_user_id,
              created_at: now
            )
          end
          revision = expected_revision.nil? ? current_revision : normalize_revision(expected_revision)
          @store.append_prices(prices, expected_revision: revision)
        end

        def current_revision
          @store.revision
        end

        def history(limit: 20)
          @store.history(limit: normalize_limit(limit))
        end

        private

        def normalize_revision(value)
          revision = Integer(value)
          raise ArgumentError if revision.negative?

          revision
        rescue ArgumentError, TypeError
          raise ArgumentError, "revision must be a non-negative integer"
        end

        def normalize_limit(value)
          limit = Integer(value)
          raise ArgumentError unless (1..100).cover?(limit)

          limit
        rescue ArgumentError, TypeError
          raise ArgumentError, "limit must be between 1 and 100"
        end

        def current_time
          value = @clock.call
          raise ArgumentError, "clock must return a Time" unless value.is_a?(Time)

          value.getutc
        end
      end
    end
  end
end
