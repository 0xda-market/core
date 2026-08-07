# frozen_string_literal: true

require "thread"
require_relative "../core/contracts"
require_relative "payout_records"

module ZeroXDA
  module Market
    module BrokerEarnings
      class MemoryStore
        def initialize
          @mutex = Mutex.new
          @earnings = {}
          @profiles = {}
          @payouts = {}
        end

        def transaction = @mutex.synchronize { yield self }
        def find_by_order(order_id) = @earnings.values.find { |earning| earning.order_id == order_id.to_s }
        def list_by_seller(seller_user_id) = @earnings.values.select { |earning| earning.seller_user_id == seller_user_id.to_s }.sort_by { |earning| [earning.updated_at, earning.id] }.reverse
        def available_by_seller(seller_user_id) = list_by_seller(seller_user_id).select { |earning| earning.state == "available" }.reverse

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

        def payout_profile(seller_user_id) = @profiles[seller_user_id.to_s]

        def upsert_payout_profile(profile, expected_version: nil)
          current = @profiles[profile.seller_user_id]
          if current && !expected_version.nil? && current.version != expected_version
            raise Core::ConcurrencyConflict.new("broker_payout_profile", profile.seller_user_id)
          end
          @profiles[profile.seller_user_id] = profile
        end

        def insert_payout(payout)
          existing = @payouts.values.find { |item| item.idempotency_key == payout.idempotency_key }
          return existing if existing
          @payouts[payout.id] = payout
        end

        def find_payout(id) = @payouts[id.to_s]
        def list_payouts(seller_user_id) = @payouts.values.select { |item| item.seller_user_id == seller_user_id.to_s }.sort_by(&:created_at).reverse

        def replace_payout(payout, expected_version:)
          current = @payouts[payout.id] || raise(Core::NotFound.new("broker_payout", payout.id))
          raise Core::ConcurrencyConflict.new("broker_payout", payout.id) unless current.version == expected_version
          @payouts[payout.id] = payout
        end
      end
    end
  end
end
