# frozen_string_literal: true

require "bigdecimal"
require_relative "competitive_reference_policy"
require_relative "automatic_price_increase_policy"
require_relative "../localization/errors"

module ZeroXDA
  module Market
    module Pricing
      class AutomaticService
        SOURCE = "core"
        PRICING_QUANTITY = BigDecimal("1")
        GUARDED_REASON = "uncorroborated_increase"
        Result = Struct.new(
          :sku,
          :status,
          :supply_cost_usdt,
          :reference_supply_cost_usdt,
          :required_price_usdt,
          :price_usdt,
          :guard_reason,
          keyword_init: true
        )

        def initialize(
          catalog:,
          pricing:,
          listings_store:,
          localization:,
          profitability:,
          reference_policy: CompetitiveReferencePolicy.new,
          increase_policy: AutomaticPriceIncreasePolicy.new
        )
          @catalog = catalog
          @pricing = pricing
          @listings_store = listings_store
          @localization = localization
          @profitability = profitability
          @reference_policy = reference_policy
          @increase_policy = increase_policy
        end

        # Automatic pricing is deliberately asymmetric:
        # - the best executable broker ask anchors a market-owned routing band;
        # - the client price covers that bounded band, settlement cost and margin;
        # - modest price rises remain automatic;
        # - anomalous rises require corroboration from independent broker supply;
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
          listings_by_sku = pricing_listings_by_sku(products)
          changes = []
          results = products.map do |product|
            supply = normalized_supply(listings_by_sku.fetch(product.sku, []))
            supply_cost = supply.map { |entry| entry.fetch(:cost_usdt) }.min
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
            if existing.nil?
              changes << { "sku" => product.sku, "amount_usdt" => required.to_s("F") }
              Result.new(
                sku: product.sku,
                status: "priced",
                supply_cost_usdt: supply_cost,
                reference_supply_cost_usdt: reference_supply_cost,
                required_price_usdt: required,
                price_usdt: required
              ).freeze
            elsif existing < required
              if @increase_policy.allow_raise?(
                current_price_usdt: existing,
                required_price_usdt: required,
                supply_costs_by_seller: cheapest_supply_by_seller(supply)
              )
                changes << { "sku" => product.sku, "amount_usdt" => required.to_s("F") }
                Result.new(
                  sku: product.sku,
                  status: "raised",
                  supply_cost_usdt: supply_cost,
                  reference_supply_cost_usdt: reference_supply_cost,
                  required_price_usdt: required,
                  price_usdt: required
                ).freeze
              else
                Result.new(
                  sku: product.sku,
                  status: "guarded",
                  supply_cost_usdt: supply_cost,
                  reference_supply_cost_usdt: reference_supply_cost,
                  required_price_usdt: required,
                  price_usdt: existing,
                  guard_reason: GUARDED_REASON
                ).freeze
              end
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

        def pricing_listings_by_sku(products)
          available = @listings_store.available_listings.group_by(&:sku)
          products.each_with_object({}) do |product, selected|
            selected[product.sku] = available.fetch(product.sku, [])
          end
        end

        def normalized_supply(listings)
          listings.filter_map do |listing|
            next if listing.available_quantity < PRICING_QUANTITY

            {
              seller_user_id: listing.seller_user_id.to_s,
              cost_usdt: amount_usdt(listing.price_amount, listing.currency)
            }.freeze
          rescue Localization::RateUnavailable
            # Unsupported or stale FX makes only this listing ineligible as a
            # pricing input. Malformed values and unexpected failures surface.
            nil
          end
        end

        def cheapest_supply_by_seller(supply)
          supply.each_with_object({}) do |entry, costs|
            seller_user_id = entry.fetch(:seller_user_id)
            cost = entry.fetch(:cost_usdt)
            current = costs[seller_user_id]
            costs[seller_user_id] = cost if current.nil? || cost < current
          end
        end

        def amount_usdt(amount, currency)
          return BigDecimal(amount.to_s) if currency == "USDT"

          unless @localization.supported_currency?(currency)
            raise Localization::RateUnavailable, "currency rate is unavailable: #{currency}"
          end

          @localization.amount_usdt(amount: amount, currency: currency)
        end
      end
    end
  end
end
