# frozen_string_literal: true

require "bigdecimal"
require "securerandom"
require "time"
require_relative "earning"
require_relative "payout_records"

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

        def record(order:, reservation:, listing:)
          existing = @store.find_by_order(order.id)
          return existing if existing
          payable = amount_usdt(reservation.supply_unit_price, reservation.supply_currency) * reservation.quantity
          now = current_time
          earning = Earning.new(id: @id_generator.call.to_s, order_id: order.id, reservation_id: reservation.id,
                                listing_id: listing.id, seller_user_id: listing.seller_user_id,
                                quantity: reservation.quantity, ask_amount: reservation.supply_unit_price,
                                ask_currency: reservation.supply_currency, payable_amount: payable.round(12),
                                payable_currency: "USDT", created_at: now)
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

        def list(actor_user_id:) = @store.list_by_seller(actor_user_id)

        def balance(actor_user_id:)
          groups = @store.list_by_seller(actor_user_id).group_by(&:state)
          sum = ->(state) { (groups[state] || []).sum(BigDecimal("0"), &:payable_amount) }
          Balance.new(pending: sum.call("pending"), available: sum.call("available"),
                      payout_queued: sum.call("payout_queued"), paid: sum.call("paid"), currency: "USDT").freeze
        end

        def payout_profile(actor_user_id:)
          @store.payout_profile(actor_user_id)
        end

        def save_payout_profile(actor_user_id:, network:, destination:, minimum_payout_amount: "0", enabled: true,
                                expected_version: nil)
          network = network.to_s.strip.upcase
          destination = destination.to_s.strip
          raise ArgumentError, "network is required" if network.empty?
          raise ArgumentError, "destination is required" if destination.empty?
          minimum = BigDecimal(minimum_payout_amount.to_s)
          raise ArgumentError, "minimum payout amount must be non-negative" if minimum.negative?
          current = @store.payout_profile(actor_user_id)
          now = current_time
          profile = PayoutProfile.new(seller_user_id: actor_user_id.to_s, currency: "USDT", network: network,
                                      destination: destination, minimum_payout_amount: minimum.round(12),
                                      enabled: !!enabled, created_at: current&.created_at || now, updated_at: now,
                                      version: current ? current.version + 1 : 0)
          @store.transaction { |store| store.upsert_payout_profile(profile, expected_version: expected_version) }
        end

        def queue_payout(actor_user_id:, idempotency_key: nil)
          profile = @store.payout_profile(actor_user_id)
          unless profile&.enabled
            raise Core::Conflict.new("payout profile is required", code: "payout_profile_required")
          end
          @store.transaction do |store|
            earnings = store.available_by_seller(actor_user_id)
            amount = earnings.sum(BigDecimal("0"), &:payable_amount)
            if amount <= 0
              raise Core::Conflict.new("no available broker earnings", code: "no_available_earnings")
            end
            if amount < BigDecimal(profile.minimum_payout_amount.to_s)
              raise Core::Conflict.new("available balance is below payout threshold", code: "payout_threshold_not_met",
                                       details: { available: amount.to_s("F"), minimum: profile.minimum_payout_amount.to_s("F") })
            end
            now = current_time
            payout = Payout.new(id: @id_generator.call.to_s, seller_user_id: actor_user_id.to_s,
                                currency: "USDT", network: profile.network, destination: profile.destination,
                                amount: amount.round(12), state: "queued",
                                idempotency_key: idempotency_key.to_s.empty? ? "broker/#{actor_user_id}/#{earnings.map(&:id).sort.join(',')}" : idempotency_key.to_s,
                                external_reference: nil, provider_data: {}, created_at: now, updated_at: now,
                                paid_at: nil, version: 0)
            persisted = store.insert_payout(payout)
            earnings.each do |earning|
              next unless earning.state == "available"
              store.replace(Earning.new(**earning.to_h.merge(state: "payout_queued", payout_id: persisted.id,
                                                              updated_at: now, version: earning.version + 1)),
                            expected_version: earning.version)
            end
            persisted
          end
        end

        def list_payouts(actor_user_id:) = @store.list_payouts(actor_user_id)

        def confirm_payout(payout_id:, external_reference:, provider_data: {})
          reference = external_reference.to_s.strip
          raise ArgumentError, "external reference is required" if reference.empty?
          @store.transaction do |store|
            current = store.find_payout(payout_id) || raise(Core::NotFound.new("broker_payout", payout_id))
            next current if current.state == "paid"
            raise Core::Conflict.new("payout is not queued", code: "payout_not_queued") unless %w[queued processing].include?(current.state)
            now = current_time
            paid = Payout.new(**current.to_h.merge(state: "paid", external_reference: reference,
                                                   provider_data: provider_data, paid_at: now,
                                                   updated_at: now, version: current.version + 1))
            paid = store.replace_payout(paid, expected_version: current.version)
            store.list_by_seller(current.seller_user_id).select { |earning| earning.payout_id == current.id && earning.state == "payout_queued" }.each do |earning|
              store.replace(Earning.new(**earning.to_h.merge(state: "paid", paid_at: now,
                                                              updated_at: now, version: earning.version + 1)),
                            expected_version: earning.version)
            end
            paid
          end
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
