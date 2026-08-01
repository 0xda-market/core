# frozen_string_literal: true

require "securerandom"
require_relative "../core/contracts"
require_relative "listing"

module ZeroXDA
  module Market
    module Listings
      class Service
        SELLER_ROLES = %w[broker admin].freeze

        def initialize(store:, users:, catalog:, clock: -> { Time.now.utc }, id_generator: SecureRandom.method(:uuid))
          @store = store
          @users = users
          @catalog = catalog
          @clock = clock
          @id_generator = id_generator
        end

        def list_owned(actor_user_id:)
          actor = active_seller(actor_user_id)
          @store.list_by_seller(actor.id, status: "active")
        end

        def create(actor_user_id:, sku:, quantity:, price_amount:, currency:)
          actor = active_seller(actor_user_id)
          product = marketable_product(sku)
          currency = currency_code(currency)
          now = current_time
          listing = Listing.new(
            id: @id_generator.call.to_s,
            seller_user_id: actor.id,
            sku: product.sku,
            quantity: quantity,
            price_amount: price_amount,
            currency: currency,
            created_at: now
          )
          @store.transaction { |store| store.insert_listing(listing) }
        end

        def update(actor_user_id:, listing_id:, quantity:, price_amount:, currency:, expected_version:)
          actor = active_seller(actor_user_id)
          currency = currency_code(currency)
          @store.transaction do |store|
            current = owned_listing(store, actor, listing_id)
            replacement = Listing.new(
              id: current.id,
              seller_user_id: current.seller_user_id,
              sku: current.sku,
              quantity: quantity,
              price_amount: price_amount,
              currency: currency,
              status: current.status,
              created_at: current.created_at,
              updated_at: current_time,
              version: current.version + 1
            )
            store.replace_listing(replacement, expected_version: version(expected_version))
          end
        end

        def withdraw(actor_user_id:, listing_id:, expected_version:)
          actor = active_seller(actor_user_id)
          @store.transaction do |store|
            current = owned_listing(store, actor, listing_id)
            replacement = Listing.new(
              id: current.id,
              seller_user_id: current.seller_user_id,
              sku: current.sku,
              quantity: current.quantity,
              price_amount: current.price_amount,
              currency: current.currency,
              status: "withdrawn",
              created_at: current.created_at,
              updated_at: current_time,
              version: current.version + 1
            )
            store.replace_listing(replacement, expected_version: version(expected_version))
          end
        end

        private

        def active_seller(user_id)
          id = Core::RecordSupport.identifier(user_id.to_s, field: "actor user id")
          user = @users.find_user(id) || raise(Core::NotFound.new("user", id))
          if user.status != "active"
            raise Core::Conflict.new("user is not active", code: "user_not_active", details: { user_id: id })
          end
          return user if SELLER_ROLES.include?(user.role)

          raise Core::Forbidden.new("broker role is required", details: { user_id: id })
        end

        def marketable_product(sku)
          product = @catalog.find_product(sku.to_s)
          return product if product.marketable?

          raise ArgumentError, "asset must be marketable"
        end

        def currency_code(value)
          code = value.to_s.strip.upcase
          currency = @catalog.currencies.find { |entry| entry.currency_code == code }
          raise ArgumentError, "currency is unavailable" unless currency

          code
        end

        def owned_listing(store, actor, listing_id)
          id = Core::RecordSupport.identifier(listing_id.to_s, field: "listing id")
          listing = store.find_listing(id) || raise(Core::NotFound.new("broker_listing", id))
          if listing.seller_user_id != actor.id
            raise Core::Forbidden.new("broker listing belongs to another user", details: { id: id })
          end
          if listing.status != "active"
            raise Core::Conflict.new("broker listing is not active", code: "listing_not_active", details: { id: id })
          end
          listing
        end

        def version(value)
          number = Integer(value)
          raise ArgumentError, "expected version must be non-negative" if number.negative?

          number
        rescue ArgumentError, TypeError
          raise ArgumentError, "expected version must be a non-negative integer"
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
