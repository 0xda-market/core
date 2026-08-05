# frozen_string_literal: true

require_relative "test_helper"
require "zero_x_da/market/pricing/client_price_presentation_policy"

class ClientPricePresentationPolicyTest < Minitest::Test
  Rounding = ZeroXDA::Market::Pricing::ClientPriceRounding

  class FixedRule
    def initialize(value)
      @value = BigDecimal(value)
    end

    def apply(_amount)
      @value
    end
  end

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

  def test_policy_depends_on_an_injected_registry_contract
    registry = Rounding::Registry.new(
      rules: { "TEST" => FixedRule.new("42") },
      default_rule: FixedRule.new("99")
    )
    policy = ZeroXDA::Market::Pricing::ClientPricePresentationPolicy.new(registry: registry)

    assert_equal BigDecimal("42"), policy.present(amount: "41", currency: "TEST")
    assert_equal BigDecimal("99"), policy.present(amount: "41", currency: "OTHER")
  end

  def test_rejects_a_rule_that_breaks_the_no_rounding_down_invariant
    registry = Rounding::Registry.new(
      rules: { "TEST" => FixedRule.new("40") },
      default_rule: FixedRule.new("40")
    )
    policy = ZeroXDA::Market::Pricing::ClientPricePresentationPolicy.new(registry: registry)

    assert_raises(ArgumentError) do
      policy.present(amount: "41", currency: "TEST")
    end
  end

  def test_step_and_ending_rules_are_independently_substitutable
    step = Rounding::StepRule.new(step: "0.05")
    ending = Rounding::EndingRule.new(endings: %w[9 49 99], cycle: "100")

    assert_equal BigDecimal("10.15"), step.apply(BigDecimal("10.121"))
    assert_equal BigDecimal("549"), ending.apply(BigDecimal("542"))
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
