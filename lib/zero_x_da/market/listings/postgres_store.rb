# frozen_string_literal: true

require "bigdecimal"
require "sequel"
require_relative "../core/contracts"
require_relative "listing"

module ZeroXDA
  module Market
    module Listings
      class PostgresStore
        def initialize(database:)
          @connection = database.connection
          @listings = @connection[Sequel.qualify(:market, :broker_listings)]
        end

        def transaction(&block)
          @connection.transaction(savepoint: true) { block.call(self) }
        end

        def list_by_seller(seller_user_id, status: "active")
          @listings.where(seller_user_id: seller_user_id.to_s, status: status)
                   .order(Sequel.desc(:updated_at), Sequel.desc(:id))
                   .all
                   .map { |row| deserialize(row) }
        end

        def find_listing(id)
          row = @listings.where(id: id.to_s).first
          row && deserialize(row)
        end

        def insert_listing(listing)
          @listings.insert(serialize(listing))
          listing
        rescue Sequel::UniqueConstraintViolation
          raise duplicate(listing)
        end

        def replace_listing(listing, expected_version:)
          count = @listings.where(id: listing.id, version: expected_version)
                           .update(serialize(listing))
          return listing if count == 1

          raise Core::NotFound.new("broker_listing", listing.id) unless @listings.where(id: listing.id).get(:id)

          raise Core::ConcurrencyConflict.new("broker_listing", listing.id)
        rescue Sequel::UniqueConstraintViolation
          raise duplicate(listing)
        end

        private

        def serialize(listing)
          {
            id: listing.id,
            seller_user_id: listing.seller_user_id,
            sku: listing.sku,
            quantity: listing.quantity,
            price_amount: listing.price_amount,
            currency: listing.currency,
            status: listing.status,
            created_at: listing.created_at,
            updated_at: listing.updated_at,
            version: listing.version
          }
        end

        def deserialize(row)
          Listing.new(
            id: row.fetch(:id).to_s,
            seller_user_id: row.fetch(:seller_user_id).to_s,
            sku: row.fetch(:sku),
            quantity: BigDecimal(row.fetch(:quantity).to_s),
            price_amount: BigDecimal(row.fetch(:price_amount).to_s),
            currency: row.fetch(:currency),
            status: row.fetch(:status),
            created_at: row.fetch(:created_at),
            updated_at: row.fetch(:updated_at),
            version: row.fetch(:version)
          )
        end

        def duplicate(listing)
          Core::Conflict.new(
            "an active listing already exists for this asset and currency",
            code: "duplicate_active_listing",
            details: { sku: listing.sku, currency: listing.currency }
          )
        end
      end
    end
  end
end
