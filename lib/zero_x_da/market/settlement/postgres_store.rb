# frozen_string_literal: true

require "sequel"
require_relative "../core/contracts"
require_relative "record"

module ZeroXDA
  module Market
    module Settlement
      class PostgresStore
        def initialize(database:)
          @connection = database.connection
          @records = @connection[Sequel.qualify(:market, :settlements)]
          @events = @connection[Sequel.qualify(:market, :settlement_events)]
        end

        def transaction
          @connection.transaction(savepoint: true) { yield self }
        end

        def insert(record)
          @records.insert(serialize(record))
          record
        rescue Sequel::UniqueConstraintViolation
          raise Core::Conflict.new("settlement already exists", code: "duplicate_record", details: { resource: "settlement", id: record.id })
        end

        def find(id)
          row = @records.where(id: id.to_s).first
          row && deserialize(row)
        end

        def fetch(id)
          find(id) || raise(Core::NotFound.new("settlement", id))
        end

        def find_by_order(order_id)
          row = @records.where(order_id: order_id.to_s).exclude(state: "failed").order(Sequel.desc(:created_at)).first
          row && deserialize(row)
        end

        def replace(record, expected_version:)
          count = @records.where(id: record.id, lock_version: expected_version).update(serialize(record))
          return record if count == 1
          raise Core::NotFound.new("settlement", record.id) unless @records.where(id: record.id).get(:id)
          raise Core::ConcurrencyConflict.new("settlement", record.id)
        end

        def append_event(event)
          document = Core::RecordSupport.document(event, field: "settlement event")
          @events.insert(
            settlement_id: document.fetch("settlement_id"),
            state: document.fetch("state"),
            provider_data: Sequel.pg_jsonb(document.fetch("provider_data", {})),
            observed_at: Time.iso8601(document.fetch("observed_at"))
          )
          event
        end

        private

        def serialize(record)
          {
            id: record.id, order_id: record.order_id, provider_key: record.provider_key,
            state: record.state, expected_usdt: record.expected_usdt,
            received_usdt: record.received_usdt, currency: record.currency,
            tolerance_bps: record.tolerance_bps, idempotency_key: record.idempotency_key,
            external_reference: record.external_reference,
            provider_data: Sequel.pg_jsonb(record.provider_data), expires_at: record.expires_at,
            lock_version: record.version, created_at: record.created_at, updated_at: record.updated_at
          }
        end

        def deserialize(row)
          Record.new(
            id: row.fetch(:id), order_id: row.fetch(:order_id), provider_key: row.fetch(:provider_key),
            state: row.fetch(:state), expected_usdt: row.fetch(:expected_usdt), received_usdt: row[:received_usdt],
            currency: row.fetch(:currency), tolerance_bps: row.fetch(:tolerance_bps), idempotency_key: row.fetch(:idempotency_key),
            external_reference: row[:external_reference], provider_data: document(row.fetch(:provider_data)), expires_at: row[:expires_at],
            created_at: row.fetch(:created_at), updated_at: row.fetch(:updated_at), version: row.fetch(:lock_version)
          )
        end

        def document(value)
          value.respond_to?(:to_hash) ? value.to_hash : value
        end
      end
    end
  end
end
