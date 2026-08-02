# frozen_string_literal: true

require "bigdecimal"
require "sequel"
require_relative "../core/contracts"
require_relative "price"

module ZeroXDA
  module Market
    module Pricing
      class PostgresStore
        ADVISORY_LOCK_ID = 824_507_231

        def initialize(database:)
          @database = database.connection
          @prices = @database[Sequel.qualify(:market, :product_prices)]
        end

        def append_price(price)
          @database.transaction do
            lock_price_catalog
            persist(price)
          end
        end

        def append_prices(prices, expected_revision:)
          @database.transaction do
            lock_price_catalog
            expected = normalize_revision(expected_revision)
            unless revision == expected
              raise Core::ConcurrencyConflict.new("price_catalog", expected)
            end

            prices.map { |price| persist(price) }
          end
        end

        def revision
          @prices.max(:id).to_i
        end

        def latest_price(sku, before: nil)
          row = scope(before)
            .where(sku: sku.to_s)
            .order(Sequel.desc(:created_at), Sequel.desc(:id))
            .first
          row && deserialize(row)
        end

        def latest_prices(before: nil)
          rows = scope(before)
            .distinct(:sku)
            .order(:sku, Sequel.desc(:created_at), Sequel.desc(:id))
            .all
          rows.each_with_object({}) do |row, selected|
            selected[row.fetch(:sku)] = deserialize(row)
          end
        end

        def history(limit: 20)
          normalized = normalize_limit(limit)
          @prices
            .order(Sequel.desc(:created_at), Sequel.desc(:id))
            .limit(normalized)
            .all
            .map { |row| deserialize(row) }
        end

        private

        def lock_price_catalog
          @database.get(Sequel.function(:pg_advisory_xact_lock, ADVISORY_LOCK_ID))
        end

        def persist(price)
          id = @prices.insert(
            sku: price.sku,
            amount_usdt: price.amount_usdt,
            source: price.source,
            set_by_user_id: price.set_by_user_id,
            created_at: price.created_at
          )
          deserialize(@prices.where(id: id).first)
        end

        def scope(before)
          before ? @prices.where { created_at < before } : @prices
        end

        def deserialize(row)
          Price.new(
            id: row.fetch(:id),
            sku: row.fetch(:sku),
            amount_usdt: BigDecimal(row.fetch(:amount_usdt).to_s),
            source: row.fetch(:source),
            set_by_user_id: row.fetch(:set_by_user_id),
            created_at: row.fetch(:created_at)
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
