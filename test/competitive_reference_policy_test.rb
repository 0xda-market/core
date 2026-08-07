# frozen_string_literal: true

require "minitest/autorun"
require "bigdecimal"
require "time"
require_relative "../lib/zero_x_da/market/pricing/competitive_reference_policy"
require_relative "../lib/zero_x_da/market/pricing/profitability_policy"
require_relative "../lib/zero_x_da/market/listings/supply_routing_policy"

class CompetitiveReferencePolicyTest < Minitest::Test
  Listing = Struct.new(:id, :created_at, keyword_init: true)

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
      supply_unit_cost_usdt: "10.51",
      quantity: 1
    )
  end

  def test_auto_price_preserves_the_two_broker_80_20_routing_contract
    reference = ZeroXDA::Market::Pricing::CompetitiveReferencePolicy.new
    profitability = ZeroXDA::Market::Pricing::ProfitabilityPolicy.new(
      minimum_margin_bps: 100,
      supply_buffer_bps: 100
    )
    routing = ZeroXDA::Market::Listings::SupplyRoutingPolicy.new
    client_price = profitability.minimum_client_unit_price_usdt(
      supply_unit_cost_usdt: reference.reference_supply_cost_usdt(cheapest_supply_cost_usdt: "10"),
      quantity: 1
    )
    created_at = Time.utc(2026, 8, 7, 14, 0, 0)
    candidates = [
      ["broker-a", "10"],
      ["broker-b", "10.4"]
    ].filter_map do |id, cost|
      next unless profitability.profitable?(
        client_total_usdt: client_price,
        supply_unit_cost_usdt: cost,
        quantity: 1
      )

      ZeroXDA::Market::Listings::SupplyRoutingPolicy::Candidate.new(
        listing: Listing.new(id: id, created_at: created_at),
        cost_usdt: BigDecimal(cost)
      )
    end

    positions = routing.positions(candidates)

    assert_equal 2, positions.length
    assert_equal "best", positions[0].status
    assert_equal BigDecimal("0.8"), positions[0].estimated_share
    assert_equal "competitive", positions[1].status
    assert_equal BigDecimal("0.2"), positions[1].estimated_share
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
