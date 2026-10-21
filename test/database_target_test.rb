# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "rbconfig"

class DatabaseTargetTest < Minitest::Test
  TARGET_CHECK = File.expand_path("../bin/check_database_target", __dir__)
  SELF_HOSTED_URL = "postgresql://market:example-test-password@market-postgres-production:1927/market"

  def run_check(environment:, url: nil, extra: {})
    variables = { "DEPLOY_ENV" => environment, "DATABASE_URL" => url }.merge(extra)
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

  # Sequel 5 lets query parameters override the URI authority and path.
  def test_production_rejects_query_and_fragment_overrides
    ["#{SELF_HOSTED_URL}?host=db.example.supabase.co",
     "#{SELF_HOSTED_URL}?port=5432",
     "#{SELF_HOSTED_URL}?database=postgres",
     "#{SELF_HOSTED_URL}?user=postgres",
     "#{SELF_HOSTED_URL}?conn_str=host%3Ddb.example.supabase.co",
     "#{SELF_HOSTED_URL}?",
     "#{SELF_HOSTED_URL}#fragment"].each do |url|
      stdout, stderr, status = run_check(environment: "production", url: url)
      refute status.success?, url
      refute_includes stdout + stderr, "example-test-password"
    end
  end

  def test_production_rejects_libpq_environment_overrides
    %w[PGHOSTADDR PGSERVICE PGSERVICEFILE PGSYSCONFDIR].each do |name|
      _stdout, stderr, status = run_check(environment: "production", url: SELF_HOSTED_URL, extra: { name => "x" })
      refute status.success?, name
      assert_includes stderr, name
    end
  end

  def test_rejects_unsupported_environment
    _stdout, stderr, status = run_check(environment: "staging", url: SELF_HOSTED_URL)

    refute status.success?
    assert_includes stderr, "unsupported deployment environment"
  end
end
