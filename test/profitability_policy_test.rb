# frozen_string_literal: true

require_relative "test_helper"
require "zero_x_da/market/pricing/profitability_policy"

class ProfitabilityPolicyTest < Minitest::Test
  def setup
    @policy = ZeroXDA::Market::Pricing::ProfitabilityPolicy.new(
      minimum_margin_bps: 500,
      supply_buffer_bps: 200,
      variable_fee_bps: 300,
      fixed_cost_usdt: "1"
    )
  end

  def test_derives_revenue_from_net_margin_instead_of_cost_markup
    assert_equal(
      BigDecimal("111.956522"),
      @policy.minimum_client_total_usdt(
        supply_unit_cost_usdt: "100",
        quantity: "1"
      )
    )
  end

  def test_amortizes_fixed_cost_across_the_requested_quantity
    assert_equal(
      BigDecimal("111.413044"),
      @policy.minimum_client_unit_price_usdt(
        supply_unit_cost_usdt: "100",
        quantity: "2"
      )
    )
  end

  def test_accepts_only_revenue_that_meets_the_configured_net_margin
    assert @policy.profitable?(
      client_total_usdt: "111.956522",
      supply_unit_cost_usdt: "100",
      quantity: "1"
    )
    refute @policy.profitable?(
      client_total_usdt: "111.956521",
      supply_unit_cost_usdt: "100",
      quantity: "1"
    )
  end

  def test_rejects_a_non_positive_margin_or_insolvent_rate_sum
    assert_raises(ArgumentError) do
      ZeroXDA::Market::Pricing::ProfitabilityPolicy.new(minimum_margin_bps: 0)
    end
    assert_raises(ArgumentError) do
      ZeroXDA::Market::Pricing::ProfitabilityPolicy.new(
        minimum_margin_bps: 5_000,
        variable_fee_bps: 5_000
      )
    end
  end
end
