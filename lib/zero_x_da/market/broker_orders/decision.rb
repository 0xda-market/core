# frozen_string_literal: true

require_relative "../core/records"

module ZeroXDA
  module Market
    module BrokerOrders
      class Decision
        STATUSES = %w[requested accepted completed].freeze

        attr_reader :order_id, :reservation_id, :seller_user_id, :status,
                    :accepted_at, :completed_at, :accepted_notified_at,
                    :completed_notified_at, :created_at, :updated_at, :version

        def initialize(
          order_id:, reservation_id:, seller_user_id:, status: "requested",
          accepted_at: nil, completed_at: nil, accepted_notified_at: nil,
          completed_notified_at: nil, created_at:, updated_at: created_at, version: 0
        )
          raise ArgumentError, "broker decision status is invalid" unless STATUSES.include?(status)
          raise ArgumentError, "requested decision cannot have transition timestamps" if status == "requested" && (accepted_at || completed_at)
          raise ArgumentError, "accepted decision requires accepted_at only" if status == "accepted" && (!accepted_at || completed_at)
          raise ArgumentError, "completed decision requires accepted_at and completed_at" if status == "completed" && (!accepted_at || !completed_at)
          raise ArgumentError, "accepted notification requires acceptance" if accepted_notified_at && !accepted_at
          raise ArgumentError, "completed notification requires completion" if completed_notified_at && !completed_at

          @order_id = Core::RecordSupport.identifier(order_id.to_s, field: "order id")
          @reservation_id = Core::RecordSupport.identifier(reservation_id.to_s, field: "reservation id")
          @seller_user_id = Core::RecordSupport.identifier(seller_user_id.to_s, field: "seller user id")
          @status = status.dup.freeze
          @accepted_at = accepted_at && Core::RecordSupport.time(accepted_at, field: "accepted_at")
          @completed_at = completed_at && Core::RecordSupport.time(completed_at, field: "completed_at")
          @accepted_notified_at = accepted_notified_at && Core::RecordSupport.time(accepted_notified_at, field: "accepted_notified_at")
          @completed_notified_at = completed_notified_at && Core::RecordSupport.time(completed_notified_at, field: "completed_notified_at")
          @created_at = Core::RecordSupport.time(created_at, field: "created_at")
          @updated_at = Core::RecordSupport.time(updated_at, field: "updated_at")
          @version = Core::RecordSupport.non_negative_integer(version, field: "version")
          freeze
        end

        def pending_notification_event
          return "broker_order_completed" if status == "completed" && completed_notified_at.nil?
          return "broker_order_accepted" if %w[accepted completed].include?(status) && accepted_notified_at.nil?

          nil
        end

        def to_h
          instance_variables.to_h { |name| [name.to_s.delete_prefix("@").to_sym, instance_variable_get(name)] }
        end
      end
    end
  end
end
