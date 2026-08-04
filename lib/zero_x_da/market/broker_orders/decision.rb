# frozen_string_literal: true

require_relative "../core/records"

module ZeroXDA
  module Market
    module BrokerOrders
      class Decision
        STATUSES = %w[requested accepted completed].freeze

        attr_reader :order_id, :reservation_id, :seller_user_id, :status,
                    :accepted_at, :completed_at, :created_at, :updated_at, :version

        def initialize(
          order_id:,
          reservation_id:,
          seller_user_id:,
          status: "requested",
          accepted_at: nil,
          completed_at: nil,
          created_at:,
          updated_at: created_at,
          version: 0
        )
          raise ArgumentError, "broker decision status is invalid" unless STATUSES.include?(status)
          if status == "requested" && (accepted_at || completed_at)
            raise ArgumentError, "requested decision cannot have transition timestamps"
          end
          if status == "accepted" && (!accepted_at || completed_at)
            raise ArgumentError, "accepted decision requires accepted_at only"
          end
          if status == "completed" && (!accepted_at || !completed_at)
            raise ArgumentError, "completed decision requires accepted_at and completed_at"
          end

          @order_id = Core::RecordSupport.identifier(order_id.to_s, field: "order id")
          @reservation_id = Core::RecordSupport.identifier(reservation_id.to_s, field: "reservation id")
          @seller_user_id = Core::RecordSupport.identifier(seller_user_id.to_s, field: "seller user id")
          @status = status.dup.freeze
          @accepted_at = accepted_at && Core::RecordSupport.time(accepted_at, field: "accepted_at")
          @completed_at = completed_at && Core::RecordSupport.time(completed_at, field: "completed_at")
          @created_at = Core::RecordSupport.time(created_at, field: "created_at")
          @updated_at = Core::RecordSupport.time(updated_at, field: "updated_at")
          @version = Core::RecordSupport.non_negative_integer(version, field: "version")
          freeze
        end

        def to_h
          {
            order_id: order_id,
            reservation_id: reservation_id,
            seller_user_id: seller_user_id,
            status: status,
            accepted_at: accepted_at,
            completed_at: completed_at,
            created_at: created_at,
            updated_at: updated_at,
            version: version
          }
        end
      end
    end
  end
end
