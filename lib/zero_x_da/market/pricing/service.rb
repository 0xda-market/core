# frozen_string_literal: true

require_relative "price"

module ZeroXDA
  module Market
    module Pricing
      class Service
        def initialize(store:, catalog:, clock: -> { Time.now.utc })
          @store = store
          @catalog = catalog
          @clock = clock
        end

        def apply_price(
          sku:,
          amount_usdt:,
          source: "admin",
          set_by_user_id: nil,
          expected_revision: nil
        )
          apply_prices(
            [{ "sku" => sku, "amount_usdt" => amount_usdt }],
            source: source,
            set_by_user_id: set_by_user_id,
            expected_revision: expected_revision
          ).first
        end

        # Validates every entry against the catalog before acquiring the store
        # revision lock, so a bulk application either appends every price or none.
        def apply_prices(
          entries,
          source: "admin",
          set_by_user_id: nil,
          expected_revision: nil
        )
          unless entries.is_a?(Array) && !entries.empty?
            raise ArgumentError, "prices must be a non-empty array"
          end

          now = current_time
          prices = entries.map do |entry|
            entry = normalize_entry(entry)
            product = @catalog.find_product(entry.fetch("sku"))
            Price.new(
              sku: product.sku,
              amount_usdt: entry.fetch("amount_usdt"),
              source: source,
              set_by_user_id: set_by_user_id,
              created_at: now
            )
          end
          revision = expected_revision.nil? ? current_revision : normalize_revision(expected_revision)
          @store.append_prices(prices, expected_revision: revision)
        end

        def current_prices
          @store.latest_prices
        end

        def current_price(sku)
          @store.latest_price(sku)
        end

        def current_revision
          @store.revision
        end

        def history(limit: 20)
          @store.history(limit: limit)
        end

        # Daily application data: for each active catalog row, the current
        # price and the latest price before the current UTC day.
        def proposal(now: current_time, locale: "en_US")
          proposal_snapshot(now: now, locale: locale).fetch(:entries)
        end

        def proposal_snapshot(now: current_time, locale: "en_US")
          day_start = Time.utc(now.year, now.month, now.day)
          current = @store.latest_prices
          previous = @store.latest_prices(before: day_start)
          entries = pricing_products(locale).map do |product|
            {
              product: product,
              current: current[product.sku],
              previous: previous[product.sku]
            }
          end
          {
            entries: entries,
            revision: current_revision,
            generated_at: now
          }.freeze
        end

        private

        def pricing_products(locale)
          products = if @catalog.respond_to?(:admin_products)
                       @catalog.admin_products(locale: locale)
                     else
                       @catalog.products(locale: locale)
                     end
          products.select { |product| !product.respond_to?(:status) || product.status == "active" }
        end

        def normalize_entry(entry)
          raise ArgumentError, "price entry must be an object" unless entry.respond_to?(:to_h)

          entry.to_h.transform_keys(&:to_s)
        end

        def normalize_revision(value)
          revision = Integer(value)
          raise ArgumentError, "revision must not be negative" if revision.negative?

          revision
        rescue ArgumentError, TypeError
          raise ArgumentError, "revision must be a non-negative integer"
        end

        def current_time
          value = @clock.call
          raise ArgumentError, "clock must return a Time" unless value.is_a?(Time)

          value.getutc
        end
      end
    end
  end
end
