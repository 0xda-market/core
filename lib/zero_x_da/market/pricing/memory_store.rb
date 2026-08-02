# frozen_string_literal: true

require_relative "../core/contracts"
require_relative "price"

module ZeroXDA
  module Market
    module Pricing
      class MemoryStore
        def initialize
          @prices = []
          @revision = 0
          @mutex = Mutex.new
        end

        def append_price(price)
          @mutex.synchronize do
            persisted = persist(price)
            @prices << persisted
            persisted
          end
        end

        def append_prices(prices, expected_revision:)
          @mutex.synchronize do
            expected = normalize_revision(expected_revision)
            unless @revision == expected
              raise Core::ConcurrencyConflict.new("price_catalog", expected)
            end

            persisted = prices.map { |price| persist(price) }
            @prices.concat(persisted)
            persisted
          end
        end

        def revision
          @mutex.synchronize { @revision }
        end

        def latest_price(sku, before: nil)
          latest_prices(before: before)[sku.to_s]
        end

        # Latest price per sku. Insertion order breaks created_at ties,
        # matching the (created_at DESC, id DESC) ordering in Postgres.
        def latest_prices(before: nil)
          @mutex.synchronize do
            @prices.each_with_object({}) do |price, selected|
              next if before && price.created_at >= before

              selected[price.sku] = price
            end
          end
        end

        def history(limit: 20)
          normalized = normalize_limit(limit)
          @mutex.synchronize { @prices.reverse.first(normalized) }
        end

        private

        def persist(price)
          @revision += 1
          Price.new(
            id: @revision,
            sku: price.sku,
            amount_usdt: price.amount_usdt,
            source: price.source,
            set_by_user_id: price.set_by_user_id,
            created_at: price.created_at
          )
        end

        def normalize_revision(value)
          revision = Integer(value)
          raise ArgumentError, "revision must not be negative" if revision.negative?

          revision
        rescue ArgumentError, TypeError
          raise ArgumentError, "revision must be a non-negative integer"
        end

        def normalize_limit(value)
          limit = Integer(value)
          raise ArgumentError, "limit must be between 1 and 100" unless (1..100).cover?(limit)

          limit
        rescue ArgumentError, TypeError
          raise ArgumentError, "limit must be between 1 and 100"
        end
      end
    end
  end
end
