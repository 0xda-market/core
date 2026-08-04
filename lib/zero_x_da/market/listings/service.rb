# frozen_string_literal: true

require "bigdecimal"
require "securerandom"
require_relative "../core/contracts"
require_relative "listing"
require_relative "reservation"

module ZeroXDA
  module Market
    module Listings
      class Service
        SELLER_ROLES = %w[broker admin].freeze
        CLIENT_PRICE_SCALE = 6

        def initialize(
          store:,
          users:,
          catalog:,
          localization: nil,
          clock: -> { Time.now.utc },
          id_generator: SecureRandom.method(:uuid)
        )
          @store = store
          @users = users
          @catalog = catalog
          @localization = localization
          @clock = clock
          @id_generator = id_generator
        end

        def list_owned(actor_user_id:)
          actor = active_seller(actor_user_id)
          @store.list_by_seller(actor.id, status: "active")
        end

        def available_skus(currency: nil)
          normalized_currency = currency && currency_code(currency)
          @store.transaction do |store|
            release_expired(store, current_time)
            store.available_skus(currency: normalized_currency)
          end
        end

        # The buyer-facing price must cover every active broker listing that
        # can currently supply the product. Supply prices are normalized into
        # USDT and rounded upward to the client price precision so the public
        # amount can never fall below the underlying listing.
        def maximum_available_prices_usdt
          @store.transaction do |store|
            release_expired(store, current_time)
            price_floors_usdt(store.available_listings)
          end
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
          requested_quantity = quantity_value(quantity)
          @store.transaction do |store|
            release_expired(store, current_time)
            current = owned_listing(store, actor, listing_id)
            committed_quantity = current.reserved_quantity + current.sold_quantity
            if requested_quantity < committed_quantity
              raise Core::Conflict.new(
                "listing quantity cannot be lower than reserved and sold inventory",
                code: "inventory_already_committed",
                details: {
                  minimum_quantity: committed_quantity.to_s("F"),
                  reserved_quantity: current.reserved_quantity.to_s("F"),
                  sold_quantity: current.sold_quantity.to_s("F")
                }
              )
            end

            replacement = rebuild_listing(
              current,
              quantity: requested_quantity,
              available_quantity: requested_quantity - committed_quantity,
              price_amount: price_amount,
              currency: currency,
              updated_at: current_time,
              version: current.version + 1
            )
            store.replace_listing(replacement, expected_version: version(expected_version))
          end
        end

        def withdraw(actor_user_id:, listing_id:, expected_version:)
          actor = active_seller(actor_user_id)
          @store.transaction do |store|
            release_expired(store, current_time)
            current = owned_listing(store, actor, listing_id)
            replacement = rebuild_listing(
              current,
              status: "withdrawn",
              updated_at: current_time,
              version: current.version + 1
            )
            store.replace_listing(replacement, expected_version: version(expected_version))
          end
        end

        def reserve(
          customer_user_id:,
          quote_id:,
          sku:,
          quantity:,
          expires_at:,
          currency: nil,
          client_unit_price_usdt: nil
        )
          customer = active_user(customer_user_id)
          product = marketable_product(sku)
          normalized_currency = currency && currency_code(currency)
          requested_quantity = quantity_value(quantity)
          expiration = Core::RecordSupport.time(expires_at, field: "reservation expires_at")
          now = current_time
          raise ArgumentError, "reservation must expire in the future" unless expiration > now

          @store.transaction do |store|
            release_expired(store, now)
            existing = store.find_reservation_by_quote(quote_id)
            next existing if existing && existing.customer_user_id == customer.id
            if existing
              raise Core::Conflict.new(
                "quote is already reserved by another customer",
                code: "duplicate_reservation",
                details: { quote_id: quote_id.to_s }
              )
            end

            available_listings = store.available_listings(sku: product.sku, for_update: true)
            ensure_client_price_covers_listings!(
              client_unit_price_usdt,
              product.sku,
              available_listings
            )
            candidates = available_listings.select do |listing|
              listing.available_quantity >= requested_quantity
            end
            candidates = candidates.select { |entry| entry.currency == normalized_currency } if normalized_currency
            listing = candidates.filter_map do |entry|
              cost = normalized_supply_cost(entry)
              cost && [entry, cost]
            end.min_by { |entry, cost| [cost, entry.created_at, entry.id] }&.first
            unless listing
              raise Core::Conflict.new(
                "insufficient broker liquidity",
                code: "insufficient_liquidity",
                details: {
                  sku: product.sku,
                  quantity: requested_quantity.to_s("F"),
                  currency: normalized_currency
                }.compact
              )
            end

            updated_listing = rebuild_listing(
              listing,
              available_quantity: listing.available_quantity - requested_quantity,
              reserved_quantity: listing.reserved_quantity + requested_quantity,
              updated_at: now,
              version: listing.version + 1
            )
            store.replace_listing(updated_listing, expected_version: listing.version)
            store.insert_reservation(
              Reservation.new(
                id: @id_generator.call.to_s,
                listing_id: listing.id,
                customer_user_id: customer.id,
                quote_id: quote_id,
                quantity: requested_quantity,
                supply_unit_price: listing.price_amount,
                supply_currency: listing.currency,
                expires_at: expiration,
                created_at: now
              )
            )
          end
        end

        def await_payment(customer_user_id:, quote_id:, order_id:)
          customer = active_user(customer_user_id)
          now = current_time
          @store.transaction do |store|
            reservation = store.find_reservation_by_quote(quote_id) ||
                          raise(Core::NotFound.new("listing_reservation", quote_id))
            ensure_reservation_owner!(reservation, customer)
            if %w[payment_pending committed].include?(reservation.status)
              if reservation.order_id == order_id.to_s
                next reservation
              end

              raise Core::Conflict.new(
                "reservation is already attached to another order",
                code: "reservation_already_attached",
                details: { quote_id: quote_id.to_s, order_id: reservation.order_id }
              )
            end
            unless reservation.active?
              raise Core::Conflict.new(
                "reservation is not active",
                code: "reservation_not_active",
                details: { quote_id: quote_id.to_s }
              )
            end
            if reservation.expired?(at: now)
              release_reservation(store, reservation, now)
              raise Core::Conflict.new(
                "reservation has expired",
                code: "reservation_expired",
                details: { quote_id: quote_id.to_s }
              )
            end

            store.replace_reservation(
              rebuild_reservation(
                reservation,
                order_id: order_id,
                status: "payment_pending",
                updated_at: now,
                version: reservation.version + 1
              ),
              expected_version: reservation.version
            )
          end
        end

        def commit_payment(order_id:)
          now = current_time
          @store.transaction do |store|
            reservation = store.find_reservation_by_order(order_id) ||
                          raise(Core::NotFound.new("listing_reservation", order_id))
            next reservation if reservation.status == "committed"
            unless reservation.payment_pending?
              raise Core::Conflict.new(
                "reservation is not waiting for payment",
                code: "payment_not_pending",
                details: { order_id: order_id.to_s, status: reservation.status }
              )
            end
            if reservation.expired?(at: now)
              release_reservation(store, reservation, now)
              raise Core::Conflict.new(
                "payment window has expired",
                code: "payment_expired",
                details: { order_id: order_id.to_s }
              )
            end

            commit_inventory(store, reservation, now)
          end
        end

        # Preserved for provider-neutral callers that intentionally commit inventory
        # without the marketplace payment gate.
        def commit(customer_user_id:, quote_id:, order_id:)
          customer = active_user(customer_user_id)
          now = current_time
          @store.transaction do |store|
            reservation = store.find_reservation_by_quote(quote_id) ||
                          raise(Core::NotFound.new("listing_reservation", quote_id))
            ensure_reservation_owner!(reservation, customer)
            if reservation.status == "committed"
              if reservation.order_id == order_id.to_s
                next reservation
              end

              raise Core::Conflict.new(
                "reservation is already committed to another order",
                code: "reservation_already_committed",
                details: { quote_id: quote_id.to_s, order_id: reservation.order_id }
              )
            end
            unless reservation.active?
              raise Core::Conflict.new(
                "reservation is not active",
                code: "reservation_not_active",
                details: { quote_id: quote_id.to_s }
              )
            end
            if reservation.expired?(at: now)
              release_reservation(store, reservation, now)
              raise Core::Conflict.new(
                "reservation has expired",
                code: "reservation_expired",
                details: { quote_id: quote_id.to_s }
              )
            end

            reservation = store.replace_reservation(
              rebuild_reservation(
                reservation,
                order_id: order_id,
                updated_at: now,
                version: reservation.version + 1
              ),
              expected_version: reservation.version
            )
            commit_inventory(store, reservation, now)
          end
        end

        def release(customer_user_id:, quote_id:)
          customer = active_user(customer_user_id)
          @store.transaction do |store|
            reservation = store.find_reservation_by_quote(quote_id) ||
                          raise(Core::NotFound.new("listing_reservation", quote_id))
            ensure_reservation_owner!(reservation, customer)
            reservation.reserving? ? release_reservation(store, reservation, current_time) : reservation
          end
        end

        def reservation_for_quote(quote_id)
          @store.find_reservation_by_quote(quote_id)
        end

        def reservation_for_order(order_id)
          @store.find_reservation_by_order(order_id)
        end

        private

        def active_seller(user_id)
          user = active_user(user_id)
          return user if SELLER_ROLES.include?(user.role)

          raise Core::Forbidden.new("broker role is required", details: { user_id: user.id })
        end

        def active_user(user_id)
          id = Core::RecordSupport.identifier(user_id.to_s, field: "actor user id")
          user = @users.find_user(id) || raise(Core::NotFound.new("user", id))
          if user.status != "active"
            raise Core::Conflict.new("user is not active", code: "user_not_active", details: { user_id: id })
          end
          user
        end

        def marketable_product(sku)
          product = @catalog.find_product(sku.to_s)
          return product if product.status == "active" && product.marketable?

          raise ArgumentError, "asset must be active and marketable"
        end

        def currency_code(value)
          code = value.to_s.strip.upcase
          currency = @catalog.currencies.find { |entry| entry.currency_code == code }
          raise ArgumentError, "currency is unavailable" unless currency

          code
        end

        def normalized_supply_cost(listing)
          return listing.price_amount if listing.currency == "USDT"
          return nil unless @localization&.supported_currency?(listing.currency)

          @localization.amount_usdt(amount: listing.price_amount, currency: listing.currency)
        end

        def price_floors_usdt(listings)
          listings.each_with_object({}) do |listing, floors|
            normalized = normalized_supply_cost(listing)
            next unless normalized

            floor = normalized.round(CLIENT_PRICE_SCALE, BigDecimal::ROUND_CEILING)
            current = floors[listing.sku]
            floors[listing.sku] = floor if current.nil? || floor > current
          end
        end

        def ensure_client_price_covers_listings!(client_unit_price_usdt, sku, listings)
          return if client_unit_price_usdt.nil?

          price = positive_decimal(client_unit_price_usdt, field: "client unit price")
          floor = price_floors_usdt(listings)[sku]
          return if floor.nil? || price >= floor

          raise Core::Conflict.new(
            "client price changed before inventory reservation",
            code: "client_price_stale",
            details: { sku: sku }
          )
        end

        def positive_decimal(value, field:)
          number = value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
          raise ArgumentError, "#{field} must be a positive number" unless number.finite? && number.positive?

          number
        rescue ArgumentError
          raise ArgumentError, "#{field} must be a positive number"
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

        def ensure_reservation_owner!(reservation, customer)
          return if reservation.customer_user_id == customer.id

          raise Core::Forbidden.new(
            "listing reservation belongs to another user",
            details: { quote_id: reservation.quote_id }
          )
        end

        def release_expired(store, now)
          store.expired_reservations(at: now).each do |reservation|
            release_reservation(store, reservation, now)
          end
        end

        def commit_inventory(store, reservation, now)
          listing = store.find_listing(reservation.listing_id) ||
                    raise(Core::NotFound.new("broker_listing", reservation.listing_id))
          if listing.reserved_quantity < reservation.quantity
            raise Core::Conflict.new(
              "reserved inventory is inconsistent",
              code: "inventory_invariant_violation",
              details: { listing_id: listing.id }
            )
          end

          store.replace_listing(
            rebuild_listing(
              listing,
              reserved_quantity: listing.reserved_quantity - reservation.quantity,
              sold_quantity: listing.sold_quantity + reservation.quantity,
              updated_at: now,
              version: listing.version + 1
            ),
            expected_version: listing.version
          )
          store.replace_reservation(
            rebuild_reservation(
              reservation,
              status: "committed",
              updated_at: now,
              version: reservation.version + 1
            ),
            expected_version: reservation.version
          )
        end

        def release_reservation(store, reservation, now)
          return reservation unless reservation.reserving?

          listing = store.find_listing(reservation.listing_id) ||
                    raise(Core::NotFound.new("broker_listing", reservation.listing_id))
          if listing.reserved_quantity < reservation.quantity
            raise Core::Conflict.new(
              "reserved inventory is inconsistent",
              code: "inventory_invariant_violation",
              details: { listing_id: listing.id }
            )
          end

          store.replace_listing(
            rebuild_listing(
              listing,
              available_quantity: listing.available_quantity + reservation.quantity,
              reserved_quantity: listing.reserved_quantity - reservation.quantity,
              updated_at: now,
              version: listing.version + 1
            ),
            expected_version: listing.version
          )
          store.replace_reservation(
            rebuild_reservation(
              reservation,
              status: "released",
              updated_at: now,
              version: reservation.version + 1
            ),
            expected_version: reservation.version
          )
        end

        def rebuild_listing(listing, **changes)
          attributes = {
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
          Listing.new(**attributes.merge(changes))
        end

        def rebuild_reservation(reservation, **changes)
          attributes = {
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
          Reservation.new(**attributes.merge(changes))
        end

        def quantity_value(value)
          number = value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
          maximum = BigDecimal("1e16")
          unless number.finite? && number.positive? && number < maximum && number.round(12) == number
            raise ArgumentError, "quantity must be a positive decimal with at most 12 fractional digits"
          end

          number
        rescue ArgumentError
          raise ArgumentError, "quantity must be a positive decimal with at most 12 fractional digits"
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
