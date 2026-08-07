# frozen_string_literal: true

require "bigdecimal"
require_relative "competitive_reference_policy"

module ZeroXDA
  module Market
    module Pricing
      class AutomaticService
        SOURCE = "core"
        PRICING_QUANTITY = BigDecimal("1")
        Result = Struct.new(
          :sku,
          :status,
          :supply_cost_usdt,
          :reference_supply_cost_usdt,
          :required_price_usdt,
          :price_usdt,
          keyword_init: true
        )

        def initialize(
          catalog:,
          pricing:,
          listings_store:,
          localization:,
          profitability:,
          reference_policy: CompetitiveReferencePolicy.new
        )
          @catalog = catalog
          @pricing = pricing
          @listings_store = listings_store
          @localization = localization
          @profitability = profitability
          @reference_policy = reference_policy
        end

        # Automatic pricing is deliberately asymmetric:
        # - the best executable broker ask anchors a market-owned routing band;
        # - the client price covers that bounded band, settlement cost and margin;
        # - price rises when the current price can no longer fund the band;
        # - cheaper broker supply does not automatically reduce a client price.
        #
        # Capturing the price revision before the price snapshot is intentional.
        # Any concurrent price write after that point makes the later application
        # stale and the store rejects it rather than overwriting newer admin/core
        # intent with a decision computed from an old snapshot.
        def reconcile
          products = @catalog.admin_products(locale: "en_US")
                             .select { |product| product.status == "active" && product.marketable? }
          revision = @pricing.current_revision
          current = @pricing.current_prices
          changes = []
          results = products.map do |product|
            supply_cost = cheapest_supply_cost_usdt(product.sku)
            unless supply_cost
              next Result.new(
                sku: product.sku,
                status: "awaiting_supply",
                price_usdt: current[product.sku]&.amount_usdt
              ).freeze
            end

            reference_supply_cost = @reference_policy.reference_supply_cost_usdt(
              cheapest_supply_cost_usdt: supply_cost
            )
            required = @profitability.minimum_client_unit_price_usdt(
              supply_unit_cost_usdt: reference_supply_cost,
              quantity: PRICING_QUANTITY
            )
            existing = current[product.sku]&.amount_usdt
            if existing.nil? || existing < required
              changes << { "sku" => product.sku, "amount_usdt" => required.to_s("F") }
              Result.new(
                sku: product.sku,
                status: existing ? "raised" : "priced",
                supply_cost_usdt: supply_cost,
                reference_supply_cost_usdt: reference_supply_cost,
                required_price_usdt: required,
                price_usdt: required
              ).freeze
            else
              Result.new(
                sku: product.sku,
                status: "stable",
                supply_cost_usdt: supply_cost,
                reference_supply_cost_usdt: reference_supply_cost,
                required_price_usdt: required,
                price_usdt: existing
              ).freeze
            end
          end

          @pricing.apply_prices(changes, source: SOURCE, expected_revision: revision) unless changes.empty?
          results.freeze
        end

        private

        def cheapest_supply_cost_usdt(sku)
          @listings_store.available_listings(sku: sku).filter_map do |listing|
            next if listing.available_quantity < PRICING_QUANTITY

            amount_usdt(listing.price_amount, listing.currency)
          rescue ArgumentError
            # Unsupported or stale FX makes this listing ineligible as a pricing
            # input. Unexpected programming/runtime failures must still surface.
            nil
          end.min
        end

        def amount_usdt(amount, currency)
          return BigDecimal(amount.to_s) if currency == "USDT"

          @localization.amount_usdt(amount: amount, currency: currency)
        end
      end
    end
  end
end
