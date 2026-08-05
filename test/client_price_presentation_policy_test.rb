# frozen_string_literal: true

require_relative "test_helper"
require "zero_x_da/market/pricing/client_price_presentation_policy"

class ClientPricePresentationPolicyTest < Minitest::Test
  def setup
    @policy = ZeroXDA::Market::Pricing::ClientPricePresentationPolicy.new
  end

  def test_rounds_high_value_currencies_up_to_five_minor_units
    assert_equal BigDecimal("22.75"), @policy.present(amount: "22.714", currency: "GBP")
    assert_equal BigDecimal("26.15"), @policy.present(amount: "26.121", currency: "EUR")
    assert_equal BigDecimal("29"), @policy.present(amount: "29", currency: "USD")
  end

  def test_uses_whole_commercial_endings_for_czk_and_huf
    assert_equal BigDecimal("669"), @policy.present(amount: "662.43", currency: "CZK")
    assert_equal BigDecimal("579"), @policy.present(amount: "578", currency: "HUF")
    assert_equal BigDecimal("10449"), @policy.present(amount: "10442", currency: "HUF")
  end

  def test_rounds_uah_and_rub_up_to_fifty
    assert_equal BigDecimal("1250"), @policy.present(amount: "1208.10", currency: "UAH")
    assert_equal BigDecimal("2350"), @policy.present(amount: "2314", currency: "RUB")
  end

  def test_unknown_currency_uses_minor_unit_ceiling
    assert_equal BigDecimal("12.35"), @policy.present(amount: "12.341", currency: "CAD")
  end

  def test_never_rounds_down
    examples = {
      "GBP" => "22.714",
      "CZK" => "662.43",
      "UAH" => "1208.10",
      "HUF" => "578",
      "CAD" => "12.341"
    }

    examples.each do |currency, amount|
      assert_operator @policy.present(amount: amount, currency: currency), :>=, BigDecimal(amount)
    end
  end
end
