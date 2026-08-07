# frozen_string_literal: true

require "monitor"
require_relative "../core/contracts"

module ZeroXDA
  module Market
    module Settlement
      class MemoryStore
        def initialize
          @lock = Monitor.new
          @records = {}
          @events = []
        end

        def transaction
          @lock.synchronize { yield self }
        end

        def insert(record)
          transaction do
            if @records.key?(record.id) || @records.values.any? { |item| item.order_id == record.order_id && item.state != "failed" }
              raise duplicate(record.id)
            end
            @records[record.id] = record
          end
          record
        end

        def find(id)
          transaction { @records[id.to_s] }
        end

        def fetch(id)
          find(id) || raise(Core::NotFound.new("settlement", id))
        end

        def find_by_order(order_id)
          transaction do
            @records.values.find { |item| item.order_id == order_id.to_s && item.state != "failed" }
          end
        end

        def replace(record, expected_version:)
          transaction do
            current = @records[record.id]
            raise Core::NotFound.new("settlement", record.id) unless current
            raise Core::ConcurrencyConflict.new("settlement", record.id) unless current.version == expected_version
            @records[record.id] = record
          end
          record
        end

        def append_event(event)
          transaction { @events << Core::RecordSupport.document(event, field: "settlement event") }
          event
        end

        def events(settlement_id: nil)
          transaction do
            selected = settlement_id ? @events.select { |event| event["settlement_id"] == settlement_id.to_s } : @events
            selected.map(&:dup)
          end
        end

        private

        def duplicate(id)
          Core::Conflict.new(
            "settlement already exists",
            code: "duplicate_record",
            details: { resource: "settlement", id: id.to_s }
          )
        end
      end
    end
  end
end
