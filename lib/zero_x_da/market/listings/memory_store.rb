# frozen_string_literal: true

require "monitor"
require_relative "../core/contracts"

module ZeroXDA
  module Market
    module Listings
      class MemoryStore
        def initialize
          @listings = {}
          @monitor = Monitor.new
        end

        def transaction
          @monitor.synchronize do
            snapshot = @listings.dup
            committed = false
            begin
              result = yield self
              committed = true
              result
            ensure
              @listings = snapshot unless committed
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
