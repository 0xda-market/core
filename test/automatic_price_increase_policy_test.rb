# frozen_string_literal: true

require "minitest/autorun"
require "bigdecimal"
require_relative "../lib/zero_x_da/market/pricing/automatic_price_increase_policy"

class AutomaticPriceIncreasePolicyTest < Minitest::Test
  def policy
    ZeroXDA::Market::Pricing::AutomaticPriceIncreasePolicy.new(
      max_uncorroborated_increase_bps: 1_500,
      corroboration_spread_bps: 1_000
    )
  end

  def test_allows_initial_price_and_small_single_broker_increase
    assert policy.allow_raise?(
      current_price_usdt: nil,
      required_price_usdt: "1000",
      supply_costs_by_seller: { "broker-a" => "900" }
    )
    assert policy.allow_raise?(
      current_price_usdt: "10",
      required_price_usdt: "11.5",
      supply_costs_by_seller: { "broker-a" => "10" }
    )
  end

  def test_guards_large_single_broker_increase
    refute policy.allow_raise?(
      current_price_usdt: "10",
      required_price_usdt: "100",
      supply_costs_by_seller: { "broker-a" => "90" }
    )
  end

  def test_allows_large_increase_when_two_distinct_brokers_corroborate
    assert policy.allow_raise?(
      current_price_usdt: "10",
      required_price_usdt: "100",
      supply_costs_by_seller: {
        "broker-a" => "90",
        "broker-b" => "95",
        "broker-c" => "200"
      }
    )
  end

  def test_distant_second_broker_does_not_corroborate
    refute policy.allow_raise?(
      current_price_usdt: "10",
      required_price_usdt: "100",
      supply_costs_by_seller: {
        "broker-a" => "90",
        "broker-b" => "100"
      }
    )
  end
end
