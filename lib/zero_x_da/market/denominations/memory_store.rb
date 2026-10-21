# frozen_string_literal: true

require_relative "../core/contracts"
require_relative "denomination"
require_relative "price"

module ZeroXDA
  module Market
    module Denominations
      class MemoryStore
        def initialize(denominations: [])
          @denominations = denominations.to_h { |denomination| [denomination.code, denomination] }
          @prices = []
          @revision = 0
          @mutex = Mutex.new
        end

        def list_denominations
          @mutex.synchronize { @denominations.values.sort_by(&:code) }
        end

        def find_denomination(code)
          @mutex.synchronize { @denominations[code.to_s] }
        end

        def append_prices(prices, expected_revision:)
          @mutex.synchronize do
            unless @revision == expected_revision
              raise Core::ConcurrencyConflict.new("denomination_price_catalog", expected_revision)
            end

            persisted = prices.map { |price| persist(price) }
            @prices.concat(persisted)
            persisted
          end
        end

        def revision
          @mutex.synchronize { @revision }
        end

        # Latest price per sku. Insertion order breaks created_at ties,
        # matching the (created_at DESC, id DESC) ordering in Postgres.
        def latest_prices(denomination:)
          @mutex.synchronize do
            @prices.each_with_object({}) do |price, selected|
              selected[price.sku] = price if price.denomination == denomination
            end
          end
        end

        def history(limit:)
          @mutex.synchronize { @prices.reverse.first(limit) }
        end

        private

        def persist(price)
          @revision += 1
          Price.new(
            id: @revision,
            sku: price.sku,
            denomination: price.denomination,
            amount_minor: price.amount_minor,
            source: price.source,
            set_by_user_id: price.set_by_user_id,
            created_at: price.created_at
          )
        end
      end
    end
  end
end
