# frozen_string_literal: true

require "bigdecimal"
require_relative "../core/records"

module ZeroXDA
  module Market
    module BrokerEarnings
      PayoutProfile = Struct.new(
        :seller_user_id, :currency, :network, :destination, :minimum_payout_amount,
        :enabled, :created_at, :updated_at, :version,
        keyword_init: true
      ) do
        def to_h = members.to_h { |name| [name, public_send(name)] }
      end

      Payout = Struct.new(
        :id, :seller_user_id, :currency, :network, :destination, :amount, :state,
        :idempotency_key, :external_reference, :provider_data, :created_at, :updated_at,
        :paid_at, :version,
        keyword_init: true
      ) do
        STATES = %w[queued processing paid failed].freeze
        def to_h = members.to_h { |name| [name, public_send(name)] }
      end
    end
  end
end
