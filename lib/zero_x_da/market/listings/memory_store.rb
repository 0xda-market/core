# frozen_string_literal: true

require "monitor"
require_relative "../core/contracts"

module ZeroXDA
  module Market
    module Listings
      class MemoryStore
        def initialize
          @listings = {}
          @reservations = {}
          @monitor = Monitor.new
        end

        def transaction
          @monitor.synchronize do
            listings_snapshot = @listings.dup
            reservations_snapshot = @reservations.dup
            committed = false
            begin
              result = yield self
              committed = true
              result
            ensure
              unless committed
                @listings = listings_snapshot
                @reservations = reservations_snapshot
              end
            end
          end
        end

        def list_by_seller(seller_user_id, status: "active")
          @monitor.synchronize do
            @listings.values
                     .select { |listing| listing.seller_user_id == seller_user_id.to_s && listing.status == status }
                     .sort_by { |listing| [listing.updated_at, listing.id] }
                     .reverse
          end
        end

        def available_skus(currency: nil)
          @monitor.synchronize do
            @listings.values
                     .select do |listing|
                       listing.status == "active" && listing.available_quantity.positive? &&
                         (currency.nil? || listing.currency == currency)
                     end
                     .map(&:sku)
                     .uniq
                     .sort
          end
        end

        def find_eligible_listing(sku:, currency:, quantity:)
          @monitor.synchronize do
            @listings.values
                     .select do |listing|
                       listing.status == "active" && listing.sku == sku.to_s &&
                         listing.currency == currency.to_s && listing.available_quantity >= quantity
                     end
                     .min_by { |listing| [listing.price_amount, listing.created_at, listing.id] }
          end
        end

        def find_listing(id)
          @monitor.synchronize { @listings[id.to_s] }
        end

        def insert_listing(listing)
          @monitor.synchronize do
            raise duplicate_id(listing.id) if @listings.key?(listing.id)
            raise duplicate_active(listing) if active_duplicate?(listing)

            @listings[listing.id] = listing
          end
          listing
        end

        def replace_listing(listing, expected_version:)
          @monitor.synchronize do
            current = @listings[listing.id]
            raise Core::NotFound.new("broker_listing", listing.id) unless current
            unless current.version == expected_version
              raise Core::ConcurrencyConflict.new("broker_listing", listing.id)
            end
            raise duplicate_active(listing) if active_duplicate?(listing, excluding: listing.id)

            @listings[listing.id] = listing
          end
          listing
        end

        def insert_reservation(reservation)
          @monitor.synchronize do
            if @reservations.key?(reservation.id) ||
               @reservations.values.any? { |current| current.quote_id == reservation.quote_id }
              raise Core::Conflict.new(
                "listing reservation already exists",
                code: "duplicate_reservation",
                details: { quote_id: reservation.quote_id }
              )
            end

            @reservations[reservation.id] = reservation
          end
          reservation
        end

        def find_reservation_by_quote(quote_id)
          @monitor.synchronize do
            @reservations.values.find { |reservation| reservation.quote_id == quote_id.to_s }
          end
        end

        def find_reservation_by_order(order_id)
          @monitor.synchronize do
            @reservations.values.find { |reservation| reservation.order_id == order_id.to_s }
          end
        end

        def expired_reservations(at:)
          @monitor.synchronize do
            @reservations.values.select { |reservation| reservation.expired?(at: at) }
          end
        end

        def replace_reservation(reservation, expected_version:)
          @monitor.synchronize do
            current = @reservations[reservation.id]
            raise Core::NotFound.new("listing_reservation", reservation.id) unless current
            unless current.version == expected_version
              raise Core::ConcurrencyConflict.new("listing_reservation", reservation.id)
            end

            @reservations[reservation.id] = reservation
          end
          reservation
        end

        private

        def active_duplicate?(listing, excluding: nil)
          return false unless listing.status == "active"

          @listings.values.any? do |current|
            current.id != excluding && current.status == "active" &&
              current.seller_user_id == listing.seller_user_id &&
              current.sku == listing.sku && current.currency == listing.currency
          end
        end

        def duplicate_active(listing)
          Core::Conflict.new(
            "an active listing already exists for this asset and currency",
            code: "duplicate_active_listing",
            details: { sku: listing.sku, currency: listing.currency }
          )
        end

        def duplicate_id(id)
          Core::Conflict.new(
            "broker listing already exists",
            code: "duplicate_record",
            details: { resource: "broker_listing", id: id }
          )
        end
      end
    end
  end
end
