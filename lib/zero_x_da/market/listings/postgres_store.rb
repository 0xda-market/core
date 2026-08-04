# frozen_string_literal: true

require "bigdecimal"
require "sequel"
require_relative "../core/contracts"
require_relative "listing"
require_relative "reservation"

module ZeroXDA
  module Market
    module Listings
      class PostgresStore
        def initialize(database:)
          @connection = database.connection
          @listings = @connection[Sequel.qualify(:market, :broker_listings)]
          @reservations = @connection[Sequel.qualify(:market, :listing_reservations)]
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

        def available_skus(currency: nil)
          scope = @listings.where(status: "active")
                           .where { available_quantity > 0 }
          scope = scope.where(currency: currency) if currency
          scope.select_map(:sku).uniq.sort
        end

        def available_listings(sku: nil, for_update: false)
          scope = @listings.where(status: "active")
                           .where { available_quantity > 0 }
          scope = scope.where(sku: sku.to_s) if sku
          scope = scope.order(:sku, :created_at, :id)
          scope = scope.for_update if for_update
          scope.all.map { |row| deserialize(row) }
        end

        def eligible_listings(sku:, quantity:)
          @listings.where(status: "active", sku: sku.to_s)
                   .where { available_quantity >= quantity }
                   .order(:created_at, :id)
                   .for_update
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

        def insert_reservation(reservation)
          @reservations.insert(serialize_reservation(reservation))
          reservation
        rescue Sequel::UniqueConstraintViolation
          raise Core::Conflict.new(
            "listing reservation already exists",
            code: "duplicate_reservation",
            details: { quote_id: reservation.quote_id }
          )
        end

        def find_reservation_by_quote(quote_id)
          row = @reservations.where(quote_id: quote_id.to_s).first
          row && deserialize_reservation(row)
        end

        def find_reservation_by_order(order_id)
          row = @reservations.where(order_id: order_id.to_s).first
          row && deserialize_reservation(row)
        end

        def expired_reservations(at:)
          @reservations.where(status: %w[active payment_pending])
                       .where { expires_at <= at }
                       .order(:expires_at, :id)
                       .for_update
                       .all
                       .map { |row| deserialize_reservation(row) }
        end

        def replace_reservation(reservation, expected_version:)
          count = @reservations.where(id: reservation.id, version: expected_version)
                               .update(serialize_reservation(reservation))
          return reservation if count == 1

          unless @reservations.where(id: reservation.id).get(:id)
            raise Core::NotFound.new("listing_reservation", reservation.id)
          end

          raise Core::ConcurrencyConflict.new("listing_reservation", reservation.id)
        rescue Sequel::UniqueConstraintViolation
          raise Core::Conflict.new(
            "listing reservation already exists",
            code: "duplicate_reservation",
            details: { quote_id: reservation.quote_id }
          )
        end

        private

        def serialize(listing)
          {
            id: listing.id,
            seller_user_id: listing.seller_user_id,
            sku: listing.sku,
            quantity: listing.quantity,
            available_quantity: listing.available_quantity,
            reserved_quantity: listing.reserved_quantity,
            sold_quantity: listing.sold_quantity,
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
            available_quantity: BigDecimal(row.fetch(:available_quantity).to_s),
            reserved_quantity: BigDecimal(row.fetch(:reserved_quantity).to_s),
            sold_quantity: BigDecimal(row.fetch(:sold_quantity).to_s),
            price_amount: BigDecimal(row.fetch(:price_amount).to_s),
            currency: row.fetch(:currency),
            status: row.fetch(:status),
            created_at: row.fetch(:created_at),
            updated_at: row.fetch(:updated_at),
            version: row.fetch(:version)
          )
        end

        def serialize_reservation(reservation)
          {
            id: reservation.id,
            listing_id: reservation.listing_id,
            customer_user_id: reservation.customer_user_id,
            quote_id: reservation.quote_id,
            order_id: reservation.order_id,
            quantity: reservation.quantity,
            supply_unit_price: reservation.supply_unit_price,
            supply_currency: reservation.supply_currency,
            status: reservation.status,
            expires_at: reservation.expires_at,
            created_at: reservation.created_at,
            updated_at: reservation.updated_at,
            version: reservation.version
          }
        end

        def deserialize_reservation(row)
          Reservation.new(
            id: row.fetch(:id).to_s,
            listing_id: row.fetch(:listing_id).to_s,
            customer_user_id: row.fetch(:customer_user_id).to_s,
            quote_id: row.fetch(:quote_id),
            order_id: row.fetch(:order_id),
            quantity: BigDecimal(row.fetch(:quantity).to_s),
            supply_unit_price: BigDecimal(row.fetch(:supply_unit_price).to_s),
            supply_currency: row.fetch(:supply_currency),
            status: row.fetch(:status),
            expires_at: row.fetch(:expires_at),
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
