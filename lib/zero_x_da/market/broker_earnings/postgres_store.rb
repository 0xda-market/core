# frozen_string_literal: true

require "sequel"
require_relative "../core/contracts"
require_relative "earning"
require_relative "payout_records"

module ZeroXDA
  module Market
    module BrokerEarnings
      class PostgresStore
        def initialize(database:)
          @connection = database.connection
          @earnings = @connection[Sequel.qualify(:market, :broker_earnings)]
          @profiles = @connection[Sequel.qualify(:market, :broker_payout_profiles)]
          @payouts = @connection[Sequel.qualify(:market, :broker_payouts)]
        end

        def transaction(&block) = @connection.transaction(savepoint: true) { block.call(self) }

        def find_by_order(order_id)
          row = @earnings.where(order_id: order_id.to_s).first
          row && deserialize_earning(row)
        end

        def list_by_seller(seller_user_id)
          @earnings.where(seller_user_id: seller_user_id.to_s)
                   .order(Sequel.desc(:updated_at), Sequel.desc(:id)).all.map { |row| deserialize_earning(row) }
        end

        def available_by_seller(seller_user_id)
          @earnings.where(seller_user_id: seller_user_id.to_s, state: "available")
                   .order(:available_at, :id).all.map { |row| deserialize_earning(row) }
        end

        def insert(earning)
          @earnings.insert(earning.to_h)
          earning
        rescue Sequel::UniqueConstraintViolation
          existing = find_by_order(earning.order_id)
          return existing if existing&.seller_user_id == earning.seller_user_id
          raise Core::Conflict.new("broker earning already exists", code: "duplicate_broker_earning",
                                   details: { order_id: earning.order_id })
        end

        def replace(earning, expected_version:)
          count = @earnings.where(id: earning.id, version: expected_version).update(earning.to_h)
          return earning if count == 1
          raise Core::NotFound.new("broker_earning", earning.id) unless @earnings.where(id: earning.id).first
          raise Core::ConcurrencyConflict.new("broker_earning", earning.id)
        end

        def payout_profile(seller_user_id)
          row = @profiles.where(seller_user_id: seller_user_id.to_s).first
          row && PayoutProfile.new(**row)
        end

        def upsert_payout_profile(profile, expected_version: nil)
          current = payout_profile(profile.seller_user_id)
          if current
            if !expected_version.nil? && current.version != expected_version
              raise Core::ConcurrencyConflict.new("broker_payout_profile", profile.seller_user_id)
            end
            count = @profiles.where(seller_user_id: profile.seller_user_id, version: current.version).update(profile.to_h)
            raise Core::ConcurrencyConflict.new("broker_payout_profile", profile.seller_user_id) unless count == 1
          else
            @profiles.insert(profile.to_h)
          end
          profile
        end

        def insert_payout(payout)
          @payouts.insert(payout.to_h)
          payout
        rescue Sequel::UniqueConstraintViolation
          row = @payouts.where(idempotency_key: payout.idempotency_key).first
          row ? Payout.new(**row) : raise
        end

        def find_payout(id)
          row = @payouts.where(id: id.to_s).first
          row && Payout.new(**row)
        end

        def list_payouts(seller_user_id)
          @payouts.where(seller_user_id: seller_user_id.to_s)
                  .order(Sequel.desc(:created_at), Sequel.desc(:id)).all.map { |row| Payout.new(**row) }
        end

        def replace_payout(payout, expected_version:)
          count = @payouts.where(id: payout.id, version: expected_version).update(payout.to_h)
          return payout if count == 1
          raise Core::NotFound.new("broker_payout", payout.id) unless @payouts.where(id: payout.id).first
          raise Core::ConcurrencyConflict.new("broker_payout", payout.id)
        end

        private

        def deserialize_earning(row)
          Earning.new(**row.slice(:id, :order_id, :reservation_id, :listing_id, :seller_user_id,
                                  :quantity, :ask_amount, :ask_currency, :payable_amount,
                                  :payable_currency, :state, :payout_id, :available_at, :paid_at,
                                  :created_at, :updated_at, :version))
        end
      end
    end
  end
end
