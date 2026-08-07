# frozen_string_literal: true

require "minitest/autorun"
require "bigdecimal"
require_relative "../lib/zero_x_da/market/pricing/competitive_reference_policy"
require_relative "../lib/zero_x_da/market/pricing/profitability_policy"

class CompetitiveReferencePolicyTest < Minitest::Test
  def test_default_headroom_keeps_brokers_within_five_percent_executable
    reference = ZeroXDA::Market::Pricing::CompetitiveReferencePolicy.new
    profitability = ZeroXDA::Market::Pricing::ProfitabilityPolicy.new(
      minimum_margin_bps: 100,
      supply_buffer_bps: 100
    )

    reference_cost = reference.reference_supply_cost_usdt(cheapest_supply_cost_usdt: "10")
    client_price = profitability.minimum_client_unit_price_usdt(
      supply_unit_cost_usdt: reference_cost,
      quantity: 1
    )

    assert_equal BigDecimal("10.5"), reference_cost
    assert profitability.profitable?(
      client_total_usdt: client_price,
      supply_unit_cost_usdt: "10.5",
      quantity: 1
    )
    refute profitability.profitable?(
      client_total_usdt: client_price,
      supply_unit_cost_usdt: "10.50000001",
      quantity: 1
    )
  end

  def test_headroom_is_market_owned_and_deterministic
    reference = ZeroXDA::Market::Pricing::CompetitiveReferencePolicy.new(routing_headroom_bps: 250)

    assert_equal BigDecimal("20.5"), reference.reference_supply_cost_usdt(cheapest_supply_cost_usdt: "20")
  end

  def test_rejects_invalid_configuration_and_cost
    assert_raises(ArgumentError) do
      ZeroXDA::Market::Pricing::CompetitiveReferencePolicy.new(routing_headroom_bps: 10_000)
    end

    reference = ZeroXDA::Market::Pricing::CompetitiveReferencePolicy.new
    assert_raises(ArgumentError) do
      reference.reference_supply_cost_usdt(cheapest_supply_cost_usdt: 0)
    end
  end
end
