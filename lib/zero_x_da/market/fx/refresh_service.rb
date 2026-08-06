# frozen_string_literal: true

require_relative "../core/contracts"
require_relative "rate_snapshot"

module ZeroXDA
  module Market
    module FX
      RefreshResult = Data.define(:snapshot, :prices)

      # Fetches one complete provider snapshot and appends it atomically through
      # the existing pricing revision contract. A concurrent administrator
      # application causes one safe retry with the same observed snapshot.
      class RefreshService
        BASE_CURRENCY = "USDT"

        def initialize(provider:, catalog:, pricing:)
          @provider = provider
          @catalog = catalog
          @pricing = pricing
        end

        def refresh
          currencies = refreshable_currencies
          raise ArgumentError, "no non-base currencies are configured" if currencies.empty?

          snapshot = @provider.fetch(currencies: currencies.keys)
          entries = currencies.map do |currency, sku|
            { "sku" => sku, "amount_usdt" => snapshot.fetch(currency) }
          end
          prices = apply(entries, source: "fx:#{snapshot.provider}")
          RefreshResult.new(snapshot: snapshot, prices: prices.freeze)
        end

        private

        def refreshable_currencies
          @catalog.currencies.each_with_object({}) do |product, selected|
            code = product.currency_code.to_s.upcase
            next if code == BASE_CURRENCY

            selected[code] = product.sku
          end.freeze
        end

        def apply(entries, source:)
          attempts = 0
          begin
            attempts += 1
            @pricing.apply_prices(
              entries,
              source: source,
              expected_revision: @pricing.current_revision
            )
          rescue Core::ConcurrencyConflict
            retry if attempts < 2

            raise
          end
        end
      end
    end
  end
end
