# frozen_string_literal: true

require "bigdecimal"
require "securerandom"
require_relative "../core/contracts"
require_relative "../pricing/profitability_policy"
require_relative "listing"
require_relative "reservation"
require_relative "supply_routing_policy"

module ZeroXDA
  module Market
    module Listings
      class Service
        SELLER_ROLES = %w[broker admin].freeze
        RoutingFeedback = Struct.new(
          :execution_status,
          :routing_status,
          :estimated_order_share,
          :eligible_supply_count,
          :sale_price_usdt,
          :maximum_ask_amount,
          :maximum_ask_currency,
          keyword_init: true
        )

        def initialize(
          store:,
          users:,
          catalog:,
          localization: nil,
          profitability: Pricing::ProfitabilityPolicy.new,
          routing: SupplyRoutingPolicy.new,
          clock: -> { Time.now.utc },
          id_generator: SecureRandom.method(:uuid)
        )
          @store = store
          @users = users
          @catalog = catalog
          @localization = localization
          @profitability = profitability
          @routing = routing
          @clock = clock
          @id_generator = id_generator
        end

        def list_owned(actor_user_id:)
          actor = active_seller(actor_user_id)
          @store.transaction do |store|
            release_expired(store, current_time)
            store.list_by_seller(actor.id, status: "active")
          end
        end

        def available_skus(currency: nil)
          normalized_currency = currency && currency_code(currency)
          @store.transaction do |store|
            release_expired(store, current_time)
            store.available_skus(currency: normalized_currency)
          end
        end

        # Availability is determined against the administrator's sale price.
        # Broker asks never alter the buyer price; unprofitable supply simply
        # cannot execute.
        def executable_skus(client_unit_prices_usdt:, quantity: 1)
          requested_quantity = quantity_value(quantity)
          prices = client_unit_prices_usdt.transform_keys(&:to_s)
          @store.transaction do |store|
            release_expired(store, current_time)
            store.available_listings.filter_map do |listing|
              next if listing.available_quantity < requested_quantity

              client_unit_price = prices[listing.sku]
              supply_cost = normalized_supply_cost(listing)
              next unless client_unit_price && supply_cost
              next unless profitable_supply?(
                client_unit_price,
                supply_cost,
                requested_quantity
              )

              listing.sku
            end.uniq.sort
          end
        end

        def routing_feedback(actor_user_id:, listing_id:, client_unit_price_usdt:)
          actor = active_seller(actor_user_id)
          requested_quantity = BigDecimal("1")
          @store.transaction do |store|
            release_expired(store, current_time)
            listing = owned_listing(store, actor, listing_id)
            feedback_for(
              listing,
              store: store,
              client_unit_price_usdt: client_unit_price_usdt,
              quantity: requested_quantity
            )
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
          client_total_price_usdt:,
          currency: nil
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
            candidates = available_listings.select do |listing|
              listing.available_quantity >= requested_quantity
            end
            candidates = candidates.select { |entry| entry.currency == normalized_currency } if normalized_currency
            executable = priced_listings(candidates).filter_map do |entry, cost|
              next unless @profitability.profitable?(
                client_total_usdt: client_total_price_usdt,
                supply_unit_cost_usdt: cost,
                quantity: requested_quantity
              )

              SupplyRoutingPolicy::Candidate.new(listing: entry, cost_usdt: cost)
            end
            selected = @routing.select(executable, seed: quote_id)
            unless selected
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
            listing = selected.listing
            supply_unit_cost_usdt = selected.cost_usdt
            ensure_profitable_quote!(
              client_total_price_usdt,
              product.sku,
              supply_unit_cost_usdt,
              requested_quantity
            )

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

        def priced_listings(listings)
          listings.filter_map do |listing|
            cost = normalized_supply_cost(listing)
            cost && [listing, cost]
          end
        end

        def profitable_supply?(client_unit_price_usdt, supply_unit_cost_usdt, quantity)
          @profitability.profitable?(
            client_total_usdt: BigDecimal(client_unit_price_usdt.to_s) * quantity,
            supply_unit_cost_usdt: supply_unit_cost_usdt,
            quantity: quantity
          )
        rescue ArgumentError, TypeError
          false
        end

        def feedback_for(listing, store:, client_unit_price_usdt:, quantity:)
          sale_price = BigDecimal(client_unit_price_usdt.to_s)
          maximum_usdt = @profitability.maximum_supply_unit_cost_usdt(
            client_unit_price_usdt: sale_price,
            quantity: quantity
          )
          maximum_ask = maximum_usdt && amount_from_usdt(
            maximum_usdt,
            currency: listing.currency
          )
          candidates = executable_candidates(
            store.available_listings(sku: listing.sku),
            client_unit_price_usdt: sale_price,
            quantity: quantity
          )
          positions = @routing.positions(candidates)
          position = positions.find { |entry| entry.candidate.listing.id == listing.id }
          supply_cost = normalized_supply_cost(listing)
          superseded = !position && listing.available_quantity >= quantity && supply_cost &&
                       profitable_supply?(sale_price, supply_cost, quantity)
          execution_status = if position
                               "executable"
                             elsif superseded
                               "superseded"
                             else
                               "not_executable"
                             end

          RoutingFeedback.new(
            execution_status: execution_status,
            routing_status: position&.status || execution_status,
            estimated_order_share: position&.estimated_share || BigDecimal("0"),
            eligible_supply_count: positions.length,
            sale_price_usdt: sale_price,
            maximum_ask_amount: maximum_ask,
            maximum_ask_currency: maximum_ask && listing.currency
          ).freeze
        rescue ArgumentError, TypeError
          RoutingFeedback.new(
            execution_status: "not_executable",
            routing_status: "not_executable",
            estimated_order_share: BigDecimal("0"),
            eligible_supply_count: 0,
            sale_price_usdt: nil,
            maximum_ask_amount: nil,
            maximum_ask_currency: nil
          ).freeze
        end

        def executable_candidates(listings, client_unit_price_usdt:, quantity:)
          candidates = priced_listings(listings).filter_map do |listing, cost|
            next if listing.available_quantity < quantity
            next unless profitable_supply?(client_unit_price_usdt, cost, quantity)

            SupplyRoutingPolicy::Candidate.new(listing: listing, cost_usdt: cost)
          end
          candidates.group_by { |candidate| candidate.listing.seller_user_id }
                    .values
                    .map do |seller_candidates|
            seller_candidates.min_by do |candidate|
              listing = candidate.listing
              [candidate.cost_usdt, listing.created_at, listing.id]
            end
          end
        end

        def amount_from_usdt(amount_usdt, currency:)
          value = if currency == "USDT"
                    amount_usdt
                  elsif @localization&.supported_currency?(currency)
                    @localization.convert(amount_usdt: amount_usdt, currency: currency)
                  end
          value&.round(8, BigDecimal::ROUND_FLOOR)
        end

        def ensure_profitable_quote!(client_total_price_usdt, sku, supply_unit_cost_usdt, quantity)
          return if @profitability.profitable?(
            client_total_usdt: client_total_price_usdt,
            supply_unit_cost_usdt: supply_unit_cost_usdt,
            quantity: quantity
          )

          raise Core::Conflict.new(
            "quote must be repriced before inventory reservation",
            code: "quote_reprice_required",
            details: { sku: sku }
          )
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
