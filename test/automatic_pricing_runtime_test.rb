# frozen_string_literal: true

require "minitest/autorun"
require "time"
require_relative "../lib/zero_x_da/market/adapters/automatic_pricing_runtime"

class AutomaticPricingRuntimeTest < Minitest::Test
  class FakeConnection
    def [](*) = Object.new
  end

  class FakeDatabase
    attr_reader :connection

    def initialize
      @connection = FakeConnection.new
      @disconnected = false
    end

    def disconnect
      @disconnected = true
    end

    def disconnected? = @disconnected
  end

  def test_composition_root_constructs_with_the_shared_clock_and_closes_database
    database = FakeDatabase.new
    clock = -> { Time.utc(2026, 8, 7, 14, 0, 0) }

    runtime = ZeroXDA::Market::Adapters::AutomaticPricingRuntime.new(
      database: database,
      minimum_margin_bps: 100,
      supply_buffer_bps: 100,
      routing_headroom_bps: 500,
      variable_fee_bps: 0,
      fixed_cost_usdt: "0",
      settlement_tolerance_bps: 0,
      max_rate_age_seconds: 3600,
      clock: clock
    )

    refute database.disconnected?
    runtime.close
    assert database.disconnected?
  end

  def test_requires_a_database_url_when_no_database_is_injected
    assert_raises(ArgumentError) do
      ZeroXDA::Market::Adapters::AutomaticPricingRuntime.new(
        minimum_margin_bps: 100,
        supply_buffer_bps: 100,
        variable_fee_bps: 0,
        fixed_cost_usdt: "0",
        settlement_tolerance_bps: 0,
        max_rate_age_seconds: 3600
      )
    end
  end
end
