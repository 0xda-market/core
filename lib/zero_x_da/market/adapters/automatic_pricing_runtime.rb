# frozen_string_literal: true

require_relative "postgres_database"
require_relative "../catalog/postgres_store"
require_relative "../catalog/service"
require_relative "../pricing/postgres_store"
require_relative "../pricing/service"
require_relative "../pricing/profitability_policy"
require_relative "../pricing/competitive_reference_policy"
require_relative "../pricing/automatic_service"
require_relative "../localization/service"
require_relative "../listings/postgres_store"
require_relative "../settlement/postgres_store"
require_relative "../settlement/manual_provider"

module ZeroXDA
  module Market
    module Adapters
      class AutomaticPricingRuntime
        def initialize(
          database_url: nil,
          minimum_margin_bps:,
          supply_buffer_bps:,
          variable_fee_bps:,
          fixed_cost_usdt:,
          settlement_tolerance_bps:,
          max_rate_age_seconds:,
          routing_headroom_bps: Pricing::CompetitiveReferencePolicy::DEFAULT_ROUTING_HEADROOM_BPS,
          clock: -> { Time.now.utc },
          database: nil
        )
          @database = database || begin
            raise ArgumentError, "database_url is required" if database_url.nil? || database_url.to_s.empty?

            PostgresDatabase.new(url: database_url, max_connections: 2)
          end
          catalog = Catalog::Service.new(
            store: Catalog::PostgresStore.new(database: @database),
            clock: clock
          )
          pricing = Pricing::Service.new(
            store: Pricing::PostgresStore.new(database: @database),
            catalog: catalog,
            clock: clock
          )
          localization = Localization::Service.new(
            catalog: catalog,
            clock: clock,
            max_rate_age_seconds: max_rate_age_seconds
          )
          settlement = Settlement::ManualProvider.new(
            clock: clock,
            store: Settlement::PostgresStore.new(database: @database),
            variable_fee_bps: variable_fee_bps,
            fixed_cost_usdt: fixed_cost_usdt,
            tolerance_bps: settlement_tolerance_bps
          )
          settlement_cost = settlement.default_cost
          profitability = Pricing::ProfitabilityPolicy.new(
            minimum_margin_bps: minimum_margin_bps,
            supply_buffer_bps: supply_buffer_bps,
            variable_fee_bps: settlement_cost.variable_fee_bps,
            fixed_cost_usdt: settlement_cost.fixed_cost_usdt
          )
          reference_policy = Pricing::CompetitiveReferencePolicy.new(
            routing_headroom_bps: routing_headroom_bps
          )
          @service = Pricing::AutomaticService.new(
            catalog: catalog,
            pricing: pricing,
            listings_store: Listings::PostgresStore.new(database: @database),
            localization: localization,
            profitability: profitability,
            reference_policy: reference_policy
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
