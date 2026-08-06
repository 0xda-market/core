# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "zero_x_da/market/adapters/coinbase_exchange_rates"

class CoinbaseExchangeRatesTest < Minitest::Test
  Adapter = ZeroXDA::Market::Adapters::CoinbaseExchangeRates

  def setup
    @now = Time.utc(2026, 8, 6, 8, 0, 0)
  end

  def test_inverts_units_per_usdt_into_the_core_buy_side_rate
    requested_uri = nil
    adapter = Adapter.new(
      clock: -> { @now },
      requester: lambda do |uri|
        requested_uri = uri
        Adapter::Response.new(
          status: 200,
          body: JSON.generate(
            data: {
              currency: "USDT",
              rates: { "USD" => "0.999", "UAH" => "44.5" }
            }
          )
        )
      end
    )

    snapshot = adapter.fetch(currencies: %w[UAH USD])

    assert_equal "currency=USDT", requested_uri.query
    assert_equal "coinbase", snapshot.provider
    assert_equal @now, snapshot.observed_at
    assert_in_delta BigDecimal("1") / BigDecimal("0.999"), snapshot.fetch("USD"), BigDecimal("0.000000000001")
    assert_in_delta BigDecimal("1") / BigDecimal("44.5"), snapshot.fetch("UAH"), BigDecimal("0.000000000001")
  end

  def test_rejects_a_partial_provider_response
    adapter = Adapter.new(
      clock: -> { @now },
      requester: ->(_uri) do
        Adapter::Response.new(
          status: 200,
          body: JSON.generate(data: { currency: "USDT", rates: { "USD" => "1" } })
        )
      end
    )

    error = assert_raises(Adapter::FetchError) do
      adapter.fetch(currencies: %w[USD UAH])
    end
    assert_includes error.message, "incomplete"
  end

  def test_rejects_non_success_status_without_parsing_the_body
    adapter = Adapter.new(
      requester: ->(_uri) { Adapter::Response.new(status: 503, body: "unavailable") }
    )

    error = assert_raises(Adapter::FetchError) do
      adapter.fetch(currencies: ["USD"])
    end
    assert_includes error.message, "503"
  end
end
