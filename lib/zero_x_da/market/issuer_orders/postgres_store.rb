# frozen_string_literal: true

require "json"
require "sequel"
require_relative "../core/contracts"
require_relative "account_link"
require_relative "order"

module ZeroXDA
  module Market
    module IssuerOrders
      class PostgresStore
        COLUMNS = %i[
          id customer_user_id idempotency_key sku denomination issuer amount_minor price_id
          recipient_subject link_provider link_provider_user_id status issuer_reference rejection_code created_at updated_at
          claimed_at completed_at version
        ].freeze

        def initialize(database:)
          @database = database.connection
          @orders = @database[Sequel.qualify(:market, :issuer_orders)]
          @events = @database[Sequel.qualify(:market, :issuer_order_events)]
          @links = @database[Sequel.qualify(:market, :issuer_account_links)]
        end

        # Returns [order, created]. A repeated idempotency key returns the
        # existing order unchanged and records no event.
        def create(order, event:)
          @database.transaction do
            inserted = @orders
              .insert_conflict(target: %i[customer_user_id idempotency_key])
              .returning(:id)
              .insert(order.to_h)
            if inserted.empty?
              existing = @orders.where(customer_user_id: order.customer_user_id,
                                       idempotency_key: order.idempotency_key).first
              next [deserialize(existing), false]
            end

            insert_event(event)
            [order, true]
          end
        end

        def find(id)
          return nil unless uuid?(id)

          row = @orders.where(id: id.to_s).first
          row && deserialize(row)
        end

        def find_by_idempotency_key(customer_user_id:, idempotency_key:)
          return nil unless uuid?(customer_user_id)

          row = @orders.where(customer_user_id: customer_user_id, idempotency_key: idempotency_key).first
          row && deserialize(row)
        end

        def find_by_issuer_reference(issuer:, reference:)
          row = @orders.where(issuer: issuer, issuer_reference: reference).first
          row && deserialize(row)
        end

        def replace(order, expected_version:, event:)
          @database.transaction do
            updated = @orders.where(id: order.id, version: expected_version)
                             .update(order.to_h.except(:id, :customer_user_id, :idempotency_key, :created_at))
            raise Core::ConcurrencyConflict.new("issuer_order", order.id) unless updated == 1

            insert_event(event)
            order
          end
        rescue Sequel::UniqueConstraintViolation
          raise Core::Conflict.new("issuer reference is already used", code: "issuer_reference_conflict",
                                                                      details: { reference: order.issuer_reference })
        end

        # Oldest first, keyset-paginated: after is the [created_at, id] of the
        # last order of the previous page.
        def list(issuer:, status:, limit:, after: nil)
          scope = @orders.where(issuer: issuer, status: status)
          scope = scope.where(Sequel.lit("(created_at, id) > (?, ?::uuid)", *after)) if after
          scope.order(:created_at, :id)
                 .limit(limit)
                 .all
                 .map { |row| deserialize(row) }
        end

        # Replaces the link for one channel account, keeping its first
        # linked_at. Another channel account of the same provider already bound
        # to that issuer account is a conflict.
        def upsert_link(link)
          row = @links
            .insert_conflict(target: %i[issuer provider provider_user_id],
                             update: { subject: Sequel[:excluded][:subject], pub_dress: Sequel[:excluded][:pub_dress],
                                       updated_at: Sequel[:excluded][:updated_at] })
            .returning
            .insert(link.to_h)
            .first
          AccountLink.new(**row.slice(*link.to_h.keys))
        rescue Sequel::UniqueConstraintViolation
          raise AccountLink.conflict(link)
        end

        def delete_link(issuer:, provider:, provider_user_id:)
          @links.where(issuer: issuer, provider: provider, provider_user_id: provider_user_id).delete == 1
        end

        def find_link(issuer:, provider:, provider_user_id:)
          row = @links.where(issuer: issuer, provider: provider, provider_user_id: provider_user_id).first
          row && AccountLink.new(**row)
        end

        def events(order_id)
          return [] unless uuid?(order_id)

          @events.where(order_id: order_id.to_s).order(:id).all.map do |row|
            Event.new(
              order_id: row.fetch(:order_id), from_status: row.fetch(:from_status), to_status: row.fetch(:to_status),
              actor: row.fetch(:actor), data: row.fetch(:data).to_h, created_at: row.fetch(:created_at)
            )
          end
        end

        private

        def insert_event(event)
          @events.insert(
            order_id: event.order_id, from_status: event.from_status, to_status: event.to_status,
            actor: event.actor, data: Sequel.pg_jsonb(event.data), created_at: event.created_at
          )
        end

        def deserialize(row)
          Order.new(**COLUMNS.to_h { |column| [column, row.fetch(column)] }.merge(
            id: row.fetch(:id).to_s, customer_user_id: row.fetch(:customer_user_id).to_s
          ))
        end

        def uuid?(value)
          value.to_s.match?(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
        end
      end
    end
  end
end
