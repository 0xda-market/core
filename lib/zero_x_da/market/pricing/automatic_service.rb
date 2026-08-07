# frozen_string_literal: true

require "bigdecimal"

module ZeroXDA
  module Market
    module Pricing
      class AutomaticService
        SOURCE = "core"
        Result = Struct.new(:sku, :status, :supply_cost_usdt, :required_price_usdt, :price_usdt, keyword_init: true)

        def initialize(catalog:, pricing:, listings_store:, localization:, profitability:)
          @catalog = catalog
          @pricing = pricing
          @listings_store = listings_store
          @localization = localization
          @profitability = profitability
        end

        # Automatic pricing is deliberately asymmetric:
        # - initial price is derived from the cheapest executable broker ask;
        # - price rises when supply can no longer satisfy the profitability floor;
        # - cheaper broker supply does not automatically reduce a client price.
        # This keeps buyer prices stable and converts broker competition into
        # additional marketplace margin until an administrator explicitly lowers
        # the client price.
        def reconcile
          products = @catalog.admin_products(locale: "en_US")
                             .select { |product| product.status == "active" && product.marketable? }
          current = @pricing.current_prices
          changes = []
          results = products.map do |product|
            supply_cost = cheapest_supply_cost_usdt(product.sku)
            unless supply_cost
              next Result.new(sku: product.sku, status: "awaiting_supply",
                              price_usdt: current[product.sku]&.amount_usdt).freeze
            end

            required = @profitability.minimum_client_unit_price_usdt(
              supply_unit_cost_usdt: supply_cost,
              quantity: 1
            )
            existing = current[product.sku]&.amount_usdt
            if existing.nil? || existing < required
              changes << { "sku" => product.sku, "amount_usdt" => required.to_s("F") }
              Result.new(sku: product.sku, status: existing ? "raised" : "priced",
                         supply_cost_usdt: supply_cost, required_price_usdt: required,
                         price_usdt: required).freeze
            else
              Result.new(sku: product.sku, status: "stable", supply_cost_usdt: supply_cost,
                         required_price_usdt: required, price_usdt: existing).freeze
            end
          end

          unless changes.empty?
            @pricing.apply_prices(changes, source: SOURCE, expected_revision: @pricing.current_revision)
          end
          results.freeze
        end

        private

        def cheapest_supply_cost_usdt(sku)
          @listings_store.available_listings(sku: sku).filter_map do |listing|
            amount_usdt(listing.price_amount, listing.currency)
          rescue StandardError
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
