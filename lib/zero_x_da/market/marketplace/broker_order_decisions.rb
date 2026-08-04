# frozen_string_literal: true

require_relative "service"

module ZeroXDA
  module Market
    module Marketplace
      module BrokerOrderDecisions
        def initialize(broker_orders: nil, **options)
          @broker_orders = broker_orders
          super(**options)
        end

        def accept(customer_user_id:, quote_id:)
          result = super
          @broker_orders&.request(order: result.order, reservation: result.reservation)
          result
        end
      end

      Service.prepend(BrokerOrderDecisions)
    end
  end
end
