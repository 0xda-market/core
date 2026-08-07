# frozen_string_literal: true

require "sequel"
require_relative "../core/contracts"
require_relative "earning"
require_relative "payout_records"

module ZeroXDA
  module Market
    module BrokerEarnings
      class PostgresStore
        ACTIVE_PAYOUT_STATES = %w[queued processing].freeze

        def initialize(database:)
          @connection = database.connection
          @earnings = @connection[Sequel.qualify(:market, :broker_earnings)]
          @profiles = @connection[Sequel.qualify(:market, :broker_payout_profiles)]
          @payouts = @connection[Sequel.qualify(:market, :broker_payouts)]
        end

        def transaction(&block)
          @connection.transaction(savepoint: true) { block.call(self) }
        end

        def find_by_order(order_id)
          row = @earnings.where(order_id: order_id.to_s).first
          row && deserialize_earning(row)
        end

        def list_by_seller(seller_user_id)
          @earnings.where(seller_user_id: seller_user_id.to_s)
                   .order(Sequel.desc(:updated_at), Sequel.desc(:id))
                   .all.map { |row| deserialize_earning(row) }
        end

        def available_by_seller(seller_user_id, for_update: false)
          scope = @earnings.where(seller_user_id: seller_user_id.to_s, state: "available")
                           .order(:available_at, :id)
          scope = scope.for_update if for_update
          scope.all.map { |row| deserialize_earning(row) }
        end

        def list_by_payout(payout_id, for_update: false)
          scope = @earnings.where(payout_id: payout_id.to_s).order(:created_at, :id)
          scope = scope.for_update if for_update
          scope.all.map { |row| deserialize_earning(row) }
        end

        def insert(earning)
          @earnings.insert(earning.to_h)
          earning
        rescue Sequel::UniqueConstraintViolation
          raise Core::Conflict.new(
            "broker earning violates a uniqueness constraint",
            code: "duplicate_broker_earning",
            details: { order_id: earning.order_id }
          )
        end

        def replace(earning, expected_version:)
          count = @earnings.where(id: earning.id, version: expected_version).update(earning.to_h)
          return earning if count == 1
          raise Core::NotFound.new("broker_earning", earning.id) unless @earnings.where(id: earning.id).first
          raise Core::ConcurrencyConflict.new("broker_earning", earning.id)
        end

        def payout_profile(seller_user_id, for_update: false)
          scope = @profiles.where(seller_user_id: seller_user_id.to_s)
          scope = scope.for_update if for_update
          row = scope.first
          row && PayoutProfile.new(**row)
        end

        def save_payout_profile(profile, expected_version:)
          current = payout_profile(profile.seller_user_id)
          if current
            count = @profiles.where(seller_user_id: profile.seller_user_id, version: expected_version)
                             .update(profile.to_h)
            raise Core::ConcurrencyConflict.new("broker_payout_profile", profile.seller_user_id) unless count == 1
          else
            raise Core::ConcurrencyConflict.new("broker_payout_profile", profile.seller_user_id) unless expected_version.nil?
            @profiles.insert(profile.to_h)
          end
          profile
        rescue Sequel::UniqueConstraintViolation
          raise Core::ConcurrencyConflict.new("broker_payout_profile", profile.seller_user_id)
        end

        def active_payout(seller_user_id, for_update: false)
          scope = @payouts.where(seller_user_id: seller_user_id.to_s, state: ACTIVE_PAYOUT_STATES)
                          .order(Sequel.desc(:created_at), Sequel.desc(:id))
          scope = scope.for_update if for_update
          row = scope.first
          row && deserialize_payout(row)
        end

        def insert_payout(payout)
          @payouts.insert(payout.to_h)
          payout
        rescue Sequel::UniqueConstraintViolation
          # Do not issue follow-up SELECTs here: PostgreSQL keeps the surrounding
          # transaction in the failed state until rollback. Normal service paths
          # classify in-flight retries before insertion under the locked profile;
          # this is the database backstop for races or direct adapter writes.
          raise Core::Conflict.new("payout violates a uniqueness constraint", code: "payout_conflict")
        end

        def find_payout(id, for_update: false)
          scope = @payouts.where(id: id.to_s)
          scope = scope.for_update if for_update
          row = scope.first
          row && deserialize_payout(row)
        end

        def list_payouts(seller_user_id)
          @payouts.where(seller_user_id: seller_user_id.to_s)
                  .order(Sequel.desc(:created_at), Sequel.desc(:id))
                  .all.map { |row| deserialize_payout(row) }
        end

        def find_payout_by_external_reference(network:, external_reference:)
          row = @payouts.where(network: network.to_s.upcase, external_reference: external_reference.to_s).first
          row && deserialize_payout(row)
        end

        def replace_payout(payout, expected_version:)
          count = @payouts.where(id: payout.id, version: expected_version).update(payout.to_h)
          return payout if count == 1
          raise Core::NotFound.new("broker_payout", payout.id) unless @payouts.where(id: payout.id).first
          raise Core::ConcurrencyConflict.new("broker_payout", payout.id)
        rescue Sequel::UniqueConstraintViolation
          raise Core::Conflict.new("external payout reference is already used", code: "duplicate_payout_reference")
        end

        private

        def deserialize_earning(row)
          Earning.new(**row.slice(:id, :order_id, :reservation_id, :listing_id, :seller_user_id,
                                  :quantity, :ask_amount, :ask_currency, :payable_amount,
                                  :payable_currency, :state, :payout_id, :available_at, :paid_at,
                                  :created_at, :updated_at, :version))
        end

        def deserialize_payout(row)
          Payout.new(**row.slice(:id, :seller_user_id, :currency, :network, :destination, :amount,
                                 :state, :idempotency_key, :external_reference, :provider_data,
                                 :created_at, :updated_at, :paid_at, :version))
        end
      end
    end
  end
end
