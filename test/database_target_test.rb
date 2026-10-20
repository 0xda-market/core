# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "rbconfig"

class DatabaseTargetTest < Minitest::Test
  TARGET_CHECK = File.expand_path("../bin/check_database_target", __dir__)
  SELF_HOSTED_URL = "postgresql://market:example-test-password@market-postgres-production:1927/market"

  def run_check(environment:, url: nil)
    variables = { "DEPLOY_ENV" => environment, "DATABASE_URL" => url }
    Open3.capture3(variables, RbConfig.ruby, TARGET_CHECK)
  end

  def test_production_accepts_only_own_self_hosted_database
    stdout, stderr, status = run_check(environment: "production", url: SELF_HOSTED_URL)

    assert status.success?, stderr
    assert_includes stdout, "Production database target verified"
  end

  def test_development_keeps_supabase_test_provider_flexible
    _stdout, stderr, status = run_check(
      environment: "development",
      url: "postgresql://test:password@db.example.supabase.co:5432/postgres"
    )

    assert status.success?, stderr
  end

  def test_production_rejects_supabase_database
    _stdout, stderr, status = run_check(
      environment: "production",
      url: "postgresql://market:password@db.example.supabase.co:5432/postgres"
    )

    refute status.success?
    assert_includes stderr, "self-hosted market-postgres-production"
  end

  def test_production_rejects_wrong_port
    _stdout, _stderr, status = run_check(
      environment: "production",
      url: "postgresql://market:password@market-postgres-production:5432/market"
    )

    refute status.success?
  end

  def test_production_rejects_wrong_database_and_user
    ["postgresql://other:password@market-postgres-production:1927/market",
     "postgresql://market:password@market-postgres-production:1927/postgres"].each do |url|
      _stdout, _stderr, status = run_check(environment: "production", url: url)
      refute status.success?
    end
  end

  def test_production_rejects_absent_or_malformed_target_without_leaking_credentials
    ["", "secret-that-is-not-a-url", "postgresql://market:leakme@@host:5432/db"].each do |url|
      stdout, stderr, status = run_check(environment: "production", url: url)
      refute status.success?
      refute_includes stdout + stderr, "leakme"
    end
  end
end
