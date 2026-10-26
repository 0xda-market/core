# frozen_string_literal: true
# © 2026 aiaiaiai · aiaiaiai.org
# SPDX-License-Identifier: MIT

require_relative "test_helper"
require "zero_x_da/market/pricing/term_promotion_policy"

class TermPromotionPolicyTest < Minitest::Test
  def setup
    @policy = ZeroXDA::Market::Pricing::TermPromotionPolicy.new
    @endings = [29, 49, 69, 99]
    @discounts = { 1 => 0, 3 => 1500, 6 => 3500, 12 => 5000 }
  end

  def test_special_prices_are_derived_before_promotion
    assert_equal %w[2.49 6.29 9.69 14.99], @discounts.map { |months, bps|
      quote("2.49", months, bps).to_s("F")
    }
  end

  def test_exclusive_uses_double_monthly_anchor_not_seeds
    assert_equal %w[4.99 12.69 19.49 29.99], @discounts.map { |months, bps|
      quote("4.98", months, bps).to_s("F")
    }
  end

  def test_promotion_is_distinct_from_upward_only_fx_presentation
    assert_equal BigDecimal("6.29"), quote("2.49", 3, 1500)
    assert_equal BigDecimal("14.99"), quote("2.49", 12, 5000)
    assert_equal BigDecimal("9.69"), quote("2.49", 6, 3500)
  end

  def test_configured_endings_are_required_and_not_global_currency_rounding
    assert_equal BigDecimal("6.49"),
                 @policy.price(monthly_usdt: "2.49", months: 3, discount_bps: 1500,
                               endings_cents: [49, 99])
    assert_equal BigDecimal("6.29"), quote("2.49", 3, 1500)
  end

  def test_equal_distance_prefers_lower_commercial_amount
    assert_equal BigDecimal("6.29"),
                 @policy.price(monthly_usdt: "6.39", months: 1, discount_bps: 0,
                               endings_cents: [29, 49])
  end

  def test_rejects_unsafe_or_invalid_values
    [
      { monthly_usdt: "0", months: 1, discount_bps: 0, endings_cents: @endings },
      { monthly_usdt: "NaN", months: 1, discount_bps: 0, endings_cents: @endings },
      { monthly_usdt: "2.49", months: 0, discount_bps: 0, endings_cents: @endings },
      { monthly_usdt: "2.49", months: 1, discount_bps: 10000, endings_cents: @endings },
      { monthly_usdt: "2.49", months: 1, discount_bps: 0, endings_cents: [] },
      { monthly_usdt: "2.49", months: 1, discount_bps: 0, endings_cents: [100] }
    ].each do |options|
      assert_raises(ArgumentError) { @policy.price(**options) }
    end
  end

  private

  def quote(monthly, months, discount)
    @policy.price(monthly_usdt: monthly, months: months,
                  discount_bps: discount, endings_cents: @endings)
  end
end
