# frozen_string_literal: true

require "sequel"
require_relative "../core/contracts"
require_relative "denomination"
require_relative "price"

module ZeroXDA
  module Market
    module Denominations
      class PostgresStore
        ADVISORY_LOCK_ID = 824_507_232

        def initialize(database:)
          @database = database.connection
          @denominations = @database[Sequel.qualify(:market, :denominations)]
          @families = @database[Sequel.qualify(:market, :denomination_product_families)]
          @prices = @database[Sequel.qualify(:market, :denomination_prices)]
        end

        def list_denominations
          families = @families.order(:family).all.group_by { |row| row.fetch(:denomination) }
          @denominations.order(:code).all.map do |row|
            deserialize_denomination(row, families.fetch(row.fetch(:code), []))
          end
        end

        def find_denomination(code)
          row = @denominations.where(code: code.to_s).first
          row && deserialize_denomination(row, @families.where(denomination: row.fetch(:code)).order(:family).all)
        end

        def append_prices(prices, expected_revision:)
          @database.transaction do
            @database.get(Sequel.function(:pg_advisory_xact_lock, ADVISORY_LOCK_ID))
            unless revision == expected_revision
              raise Core::ConcurrencyConflict.new("denomination_price_catalog", expected_revision)
            end

            prices.map { |price| persist(price) }
          end
        rescue Sequel::CheckConstraintViolation
          # The eligibility trigger re-checks each row under the lock, so a
          # product changed after service validation is a validation error.
          raise ArgumentError, "denomination price batch contains a product that is no longer eligible"
        end

        def revision
          @prices.max(:id).to_i
        end

        def latest_prices(denomination:)
          rows = @prices
            .where(denomination: denomination)
            .distinct(:sku)
            .order(:sku, Sequel.desc(:id))
            .all
          rows.to_h { |row| [row.fetch(:sku), deserialize_price(row)] }
        end

        def history(limit:)
          @prices
            .order(Sequel.desc(:id))
            .limit(limit)
            .all
            .map { |row| deserialize_price(row) }
        end

        private

        def persist(price)
          id = @prices.insert(
            sku: price.sku,
            denomination: price.denomination,
            amount_minor: price.amount_minor,
            source: price.source,
            set_by_user_id: price.set_by_user_id,
            created_at: price.created_at
          )
          deserialize_price(@prices.where(id: id).first)
        end

        def deserialize_denomination(row, family_rows)
          Denomination.new(
            code: row.fetch(:code),
            symbol: row.fetch(:symbol),
            scale: row.fetch(:scale),
            issuer: row.fetch(:issuer),
            status: row.fetch(:status),
            product_families: family_rows.map { |family| family.fetch(:family) },
            created_at: row.fetch(:created_at)
          )
        end

        def deserialize_price(row)
          Price.new(
            id: row.fetch(:id),
            sku: row.fetch(:sku),
            denomination: row.fetch(:denomination),
            amount_minor: row.fetch(:amount_minor),
            source: row.fetch(:source),
            set_by_user_id: row.fetch(:set_by_user_id),
            created_at: row.fetch(:created_at)
          )
        end
      end
    end
  end
end
