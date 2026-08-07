# frozen_string_literal: true

require "sequel"
require_relative "../core/contracts"
require_relative "earning"

module ZeroXDA
  module Market
    module BrokerEarnings
      class PostgresStore
        def initialize(database:)
          @connection = database.connection
          @earnings = @connection[Sequel.qualify(:market, :broker_earnings)]
        end

        def transaction(&block)
          @connection.transaction(savepoint: true) { block.call(self) }
        end

        def find_by_order(order_id)
          row = @earnings.where(order_id: order_id.to_s).first
          row && deserialize(row)
        end

        def list_by_seller(seller_user_id)
          @earnings.where(seller_user_id: seller_user_id.to_s)
                   .order(Sequel.desc(:updated_at), Sequel.desc(:id))
                   .all.map { |row| deserialize(row) }
        end

        def insert(earning)
          @earnings.insert(serialize(earning))
          earning
        rescue Sequel::UniqueConstraintViolation
          existing = find_by_order(earning.order_id)
          return existing if existing&.seller_user_id == earning.seller_user_id
          raise Core::Conflict.new("broker earning already exists", code: "duplicate_broker_earning",
                                   details: { order_id: earning.order_id })
        end

        def replace(earning, expected_version:)
          count = @earnings.where(id: earning.id, version: expected_version).update(serialize(earning))
          return earning if count == 1
          raise Core::NotFound.new("broker_earning", earning.id) unless @earnings.where(id: earning.id).first
          raise Core::ConcurrencyConflict.new("broker_earning", earning.id)
        end

        private

        def serialize(earning)
          earning.to_h
        end

        def deserialize(row)
          Earning.new(**row.slice(:id, :order_id, :reservation_id, :listing_id, :seller_user_id,
                                  :quantity, :ask_amount, :ask_currency, :payable_amount,
                                  :payable_currency, :state, :payout_id, :available_at, :paid_at,
                                  :created_at, :updated_at, :version))
        end
      end
    end
  end
end
