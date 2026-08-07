# frozen_string_literal: true

require_relative "postgres_database"
require_relative "../catalog/postgres_store"
require_relative "../catalog/service"
require_relative "../pricing/postgres_store"
require_relative "../pricing/service"
require_relative "../pricing/profitability_policy"
require_relative "../pricing/automatic_service"
require_relative "../localization/service"
require_relative "../listings/postgres_store"

module ZeroXDA
  module Market
    module Adapters
      class AutomaticPricingRuntime
        def initialize(database_url:, minimum_margin_bps:, supply_buffer_bps:, variable_fee_bps:, fixed_cost_usdt:,
                       max_rate_age_seconds:)
          @database = PostgresDatabase.new(url: database_url, max_connections: 2)
          catalog = Catalog::Service.new(store: Catalog::PostgresStore.new(database: @database))
          pricing = Pricing::Service.new(store: Pricing::PostgresStore.new(database: @database), catalog: catalog)
          localization = Localization::Service.new(catalog: catalog, max_rate_age_seconds: max_rate_age_seconds)
          profitability = Pricing::ProfitabilityPolicy.new(
            minimum_margin_bps: minimum_margin_bps,
            supply_buffer_bps: supply_buffer_bps,
            variable_fee_bps: variable_fee_bps,
            fixed_cost_usdt: fixed_cost_usdt
          )
          @service = Pricing::AutomaticService.new(
            catalog: catalog,
            pricing: pricing,
            listings_store: Listings::PostgresStore.new(database: @database),
            localization: localization,
            profitability: profitability
          )
        end

        def refresh
          @service.reconcile
        end

        def close
          @database.disconnect
        end
      end
    end
  end
end
