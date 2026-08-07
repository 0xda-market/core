# frozen_string_literal: true

require "thread"
require_relative "../core/contracts"

module ZeroXDA
  module Market
    module BrokerEarnings
      class MemoryStore
        def initialize
          @mutex = Mutex.new
          @earnings = {}
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
      end
    end
  end
end
