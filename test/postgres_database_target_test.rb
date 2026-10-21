# frozen_string_literal: true

require_relative "test_helper"
require "zero_x_da/market/adapters/postgres_database"
require "zero_x_da/market/adapters/fx_refresh_runtime"
require "zero_x_da/market/adapters/automatic_pricing_runtime"

# The target guard sits at the shared connection boundary, so processes that
# skip bin/check_database_target (FX and pricing workers) are covered too.
class PostgresDatabaseTargetTest < Minitest::Test
  SUPABASE_URL = "postgresql://market:password@db.example.supabase.co:5432/postgres"
  BYPASS_URL = "postgresql://market:password@market-postgres-production:1927/market?host=db.example.supabase.co"

  def setup
    @previous = ENV.fetch("DEPLOY_ENV", nil)
    ENV["DEPLOY_ENV"] = "production"
  end

  def teardown
    ENV["DEPLOY_ENV"] = @previous
  end

  def test_production_connection_is_refused_before_sequel_connects
    Sequel.stub(:connect, ->(*) { flunk "Sequel.connect must not be reached" }) do
      [SUPABASE_URL, BYPASS_URL].each do |url|
        assert_raises(ZeroXDA::Market::Adapters::DatabaseTarget::InvalidTarget) do
          ZeroXDA::Market::Adapters::PostgresDatabase.new(url: url)
        end
      end
    end
  end

  def test_fx_refresh_worker_refuses_wrong_production_database
    Sequel.stub(:connect, ->(*) { flunk "Sequel.connect must not be reached" }) do
      assert_raises(ZeroXDA::Market::Adapters::DatabaseTarget::InvalidTarget) do
        ZeroXDA::Market::Adapters::FXRefreshRuntime.new(database_url: BYPASS_URL)
      end
    end
  end

  def test_price_refresh_worker_refuses_wrong_production_database
    Sequel.stub(:connect, ->(*) { flunk "Sequel.connect must not be reached" }) do
      assert_raises(ZeroXDA::Market::Adapters::DatabaseTarget::InvalidTarget) do
        ZeroXDA::Market::Adapters::AutomaticPricingRuntime.new(
          database_url: SUPABASE_URL,
          minimum_margin_bps: 100,
          supply_buffer_bps: 0,
          variable_fee_bps: 0,
          fixed_cost_usdt: "0",
          settlement_tolerance_bps: 0,
          max_rate_age_seconds: 60
        )
      end
    end
  end
end
