# frozen_string_literal: true

require "thread"
require_relative "../core/contracts"
require_relative "payout_records"

module ZeroXDA
  module Market
    module BrokerEarnings
      class MemoryStore
        ACTIVE_PAYOUT_STATES = %w[queued processing].freeze

        def initialize
          @mutex = Mutex.new
          @earnings = {}
          @profiles = {}
          @payouts = {}
        end

        def transaction
          @mutex.synchronize { yield self }
        end

        def find_by_order(order_id)
          @earnings.values.find { |earning| earning.order_id == order_id.to_s }
        end

        def list_by_seller(seller_user_id)
          @earnings.values.select { |earning| earning.seller_user_id == seller_user_id.to_s }
                   .sort_by { |earning| [earning.updated_at, earning.id] }.reverse
        end

        def available_by_seller(seller_user_id, for_update: false)
          list_by_seller(seller_user_id).select { |earning| earning.state == "available" }
                                       .sort_by { |earning| [earning.available_at, earning.id] }
        end

        def list_by_payout(payout_id, for_update: false)
          @earnings.values.select { |earning| earning.payout_id == payout_id.to_s }
                   .sort_by { |earning| [earning.created_at, earning.id] }
        end

        def insert(earning)
          existing = find_by_order(earning.order_id)
          return existing if existing&.seller_user_id == earning.seller_user_id
          raise Core::Conflict.new("broker earning already exists", code: "duplicate_broker_earning") if existing
          @earnings[earning.id] = earning
        end

        def replace(earning, expected_version:)
          current = @earnings[earning.id] || raise(Core::NotFound.new("broker_earning", earning.id))
          raise Core::ConcurrencyConflict.new("broker_earning", earning.id) unless current.version == expected_version
          @earnings[earning.id] = earning
        end

        def payout_profile(seller_user_id, for_update: false)
          @profiles[seller_user_id.to_s]
        end

        def save_payout_profile(profile, expected_version:)
          current = @profiles[profile.seller_user_id]
          if current
            unless expected_version == current.version
              raise Core::ConcurrencyConflict.new("broker_payout_profile", profile.seller_user_id)
            end
          elsif !expected_version.nil?
            raise Core::ConcurrencyConflict.new("broker_payout_profile", profile.seller_user_id)
          end

          @profiles[profile.seller_user_id] = profile
        end

        def active_payout(seller_user_id, for_update: false)
          @payouts.values.find do |payout|
            payout.seller_user_id == seller_user_id.to_s && ACTIVE_PAYOUT_STATES.include?(payout.state)
          end
        end

        def insert_payout(payout)
          if @payouts.values.any? { |item| item.idempotency_key == payout.idempotency_key }
            raise Core::Conflict.new("payout idempotency key already exists", code: "payout_idempotency_conflict")
          end
          if active_payout(payout.seller_user_id)
            raise Core::Conflict.new("broker already has an in-flight payout", code: "payout_in_flight")
          end

          @payouts[payout.id] = payout
        end

        def find_payout(id, for_update: false)
          @payouts[id.to_s]
        end

        def list_payouts(seller_user_id)
          @payouts.values.select { |payout| payout.seller_user_id == seller_user_id.to_s }
                  .sort_by { |payout| [payout.created_at, payout.id] }.reverse
        end

        def find_payout_by_external_reference(network:, external_reference:)
          @payouts.values.find do |payout|
            payout.network == network.to_s.upcase && payout.external_reference == external_reference.to_s
          end
        end

        def replace_payout(payout, expected_version:)
          current = @payouts[payout.id] || raise(Core::NotFound.new("broker_payout", payout.id))
          raise Core::ConcurrencyConflict.new("broker_payout", payout.id) unless current.version == expected_version

          duplicate = find_payout_by_external_reference(
            network: payout.network,
            external_reference: payout.external_reference
          ) if payout.external_reference
          if duplicate && duplicate.id != payout.id
            raise Core::Conflict.new("external payout reference is already used", code: "duplicate_payout_reference")
          end

          @payouts[payout.id] = payout
        end
      end
    end
  end
end
