# frozen_string_literal: true

require "sequel"
require_relative "../core/contracts"
require_relative "decision"

module ZeroXDA
  module Market
    module BrokerOrders
      class PostgresStore
        def initialize(database:)
          @connection = database.connection
          @decisions = @connection[Sequel.qualify(:market, :broker_order_decisions)]
        end

        def transaction(&block)
          @connection.transaction(savepoint: true) { block.call(self) }
        end

        def find(order_id)
          row = @decisions.where(order_id: order_id.to_s).first
          row && deserialize(row)
        end

        def list_by_seller(seller_user_id)
          @decisions.where(seller_user_id: seller_user_id.to_s)
                    .order(Sequel.desc(:updated_at), Sequel.desc(:order_id))
                    .all.map { |row| deserialize(row) }
        end

        def insert(decision)
          @decisions.insert(serialize(decision))
          decision
        rescue Sequel::UniqueConstraintViolation
          existing = find(decision.order_id)
          return existing if existing&.seller_user_id == decision.seller_user_id

          raise Core::Conflict.new(
            "broker order decision already exists",
            code: "duplicate_broker_order_decision",
            details: { order_id: decision.order_id }
          )
        end

        def replace(decision, expected_version:)
          count = @decisions.where(order_id: decision.order_id, version: expected_version)
                            .update(serialize(decision))
          return decision if count == 1

          raise Core::NotFound.new("broker_order_decision", decision.order_id) unless find(decision.order_id)

          raise Core::ConcurrencyConflict.new("broker_order_decision", decision.order_id)
        end

        private

        def serialize(decision)
          decision.to_h
        end

        def deserialize(row)
          Decision.new(**row.slice(
            :order_id, :reservation_id, :seller_user_id, :status,
            :accepted_at, :completed_at, :accepted_notified_at,
            :completed_notified_at, :created_at, :updated_at, :version
          ))
        end
      end
    end
  end
end
