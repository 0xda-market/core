# frozen_string_literal: true

require_relative "postgres_database"
require_relative "../catalog/postgres_store"
require_relative "../catalog/service"
require_relative "../pricing/postgres_store"
require_relative "../pricing/service"
require_relative "../fx/refresh_service"
require_relative "coinbase_exchange_rates"

module ZeroXDA
  module Market
    module Adapters
      # Composition boundary for the standalone FX refresh process.
      class FXRefreshRuntime
        def initialize(
          database_url:,
          provider_name: "coinbase",
          request_timeout_seconds: CoinbaseExchangeRates::DEFAULT_TIMEOUT_SECONDS,
          clock: -> { Time.now.utc },
          requester: nil
        )
          provider = build_provider(
            provider_name,
            timeout_seconds: request_timeout_seconds,
            clock: clock,
            requester: requester
          )
          @database = PostgresDatabase.new(url: database_url, max_connections: 2)
          catalog = Catalog::Service.new(
            store: Catalog::PostgresStore.new(database: @database),
            clock: clock
          )
          pricing = Pricing::Service.new(
            store: Pricing::PostgresStore.new(database: @database),
            catalog: catalog,
            clock: clock
          )
          @service = FX::RefreshService.new(
            provider: provider,
            catalog: catalog,
            pricing: pricing
          )
        end

        def refresh
          @service.refresh
        end

        def close
          @database.disconnect
        end

        private

        def build_provider(name, **options)
          case name.to_s.strip.downcase
          when "coinbase"
            CoinbaseExchangeRates.new(**options)
          else
            raise ArgumentError, "unsupported FX rate provider: #{name}"
          end
        end
      end
    end
  end
end
