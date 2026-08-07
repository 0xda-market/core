# frozen_string_literal: true

require "bigdecimal"
require "securerandom"
require_relative "earning"

module ZeroXDA
  module Market
    module BrokerEarnings
      Balance = Struct.new(:pending, :available, :payout_queued, :paid, :currency, keyword_init: true)

      class Service
        def initialize(store:, localization:, clock: -> { Time.now.utc }, id_generator: SecureRandom.method(:uuid))
          @store = store
          @localization = localization
          @clock = clock
          @id_generator = id_generator
        end

        # Broker-first invariant: the listing ask is what the broker earns.
        # Marketplace fees, settlement costs and client pricing never reduce it.
        def record(order:, reservation:, listing:)
          existing = @store.find_by_order(order.id)
          return existing if existing

          payable = amount_usdt(reservation.supply_unit_price, reservation.supply_currency) * reservation.quantity
          now = current_time
          earning = Earning.new(
            id: @id_generator.call.to_s,
            order_id: order.id,
            reservation_id: reservation.id,
            listing_id: listing.id,
            seller_user_id: listing.seller_user_id,
            quantity: reservation.quantity,
            ask_amount: reservation.supply_unit_price,
            ask_currency: reservation.supply_currency,
            payable_amount: payable.round(12),
            payable_currency: "USDT",
            created_at: now
          )
          @store.transaction { |store| store.insert(earning) }
        end

        def make_available(order_id:)
          @store.transaction do |store|
            current = store.find_by_order(order_id) || raise(Core::NotFound.new("broker_earning", order_id))
            next current if %w[available payout_queued paid].include?(current.state)
            raise Core::Conflict.new("broker earning is not pending", code: "earning_not_pending") unless current.state == "pending"
            now = current_time
            store.replace(Earning.new(**current.to_h.merge(state: "available", available_at: now,
                                                            updated_at: now, version: current.version + 1)),
                          expected_version: current.version)
          end
        end

        def list(actor_user_id:)
          @store.list_by_seller(actor_user_id)
        end

        def balance(actor_user_id:)
          groups = @store.list_by_seller(actor_user_id).group_by(&:state)
          sum = ->(state) { (groups[state] || []).sum(BigDecimal("0"), &:payable_amount) }
          Balance.new(pending: sum.call("pending"), available: sum.call("available"),
                      payout_queued: sum.call("payout_queued"), paid: sum.call("paid"), currency: "USDT").freeze
        end

        private

        def amount_usdt(amount, currency)
          return BigDecimal(amount.to_s) if currency == "USDT"
          @localization.amount_usdt(amount: amount, currency: currency)
        end

        def current_time
          value = @clock.call
          value.is_a?(Time) ? value.utc : Time.parse(value.to_s).utc
        end
      end
    end
  end
end
