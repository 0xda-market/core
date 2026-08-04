# frozen_string_literal: true

require_relative "../core/contracts"
require_relative "service"

module ZeroXDA
  module Market
    module Listings
      module BrokerOrderAccess
        BrokerOrderContext = Struct.new(:reservation, :listing, keyword_init: true)

        def broker_order_context(actor_user_id:, order_id:)
          actor = send(:active_seller, actor_user_id)
          reservation = reservation_for_order(order_id) ||
                        raise(Core::NotFound.new("listing_reservation", order_id))
          listing = @store.find_listing(reservation.listing_id) ||
                    raise(Core::NotFound.new("broker_listing", reservation.listing_id))
          unless listing.seller_user_id == actor.id
            raise Core::Forbidden.new(
              "marketplace order belongs to another broker",
              details: { order_id: order_id.to_s }
            )
          end

          BrokerOrderContext.new(reservation: reservation, listing: listing)
        end

        def broker_order_context_for_reservation(reservation)
          listing = @store.find_listing(reservation.listing_id) ||
                    raise(Core::NotFound.new("broker_listing", reservation.listing_id))
          BrokerOrderContext.new(reservation: reservation, listing: listing)
        end
      end

      Service.prepend(BrokerOrderAccess)
    end
  end
end
