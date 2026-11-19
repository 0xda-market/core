# frozen_string_literal: true
# © 2026 aiaiaiai · aiaiaiai.org

require_relative "test_helper"
require "yaml"
require "open3"

class ProductionSeedsPublicationTest < Minitest::Test
  def preflight(values)
    source = YAML.safe_load(File.read(File.expand_path("../.github/workflows/ci.yml", __dir__)))
    step = source.fetch("jobs").fetch("publish-production").fetch("steps").find { |item| item["name"] == "Seal the production credentials to the edge-prod-1 recipient" }
    # Execute the actual publication validation, ending before any network/write.
    script = step.fetch("run").split("# Core's DatabaseTarget", 2).first
    expected = %w[PARTNER_LOOKUP_TOKEN CHANNEL_ASSERTION_SECRET]
    expected.each { |key| assert_equal "${{ secrets.#{key} }}", step.fetch("env").fetch(key) }
    Open3.capture3(valid.merge(values), "bash", "-c", script)
  end

  def test_valid_distinct_keys_pass
    _out, err, status = preflight({})
    assert status.success?, err
  end

  def test_missing_short_multiline_and_reused_keys_fail_without_disclosing_values
    [{ "PARTNER_LOOKUP_TOKEN" => "" }, { "CHANNEL_ASSERTION_SECRET" => "short-private-value" },
     { "PARTNER_LOOKUP_TOKEN" => "private-value\ninjected" },
     { "CHANNEL_ASSERTION_SECRET" => "p" * 40 }].each do |values|
      out, err, status = preflight(values)
      refute status.success?
      refute_includes out + err, "short-private-value"
      refute_includes out + err, "private-value"
      refute_includes out + err, "p" * 40
    end
  end

  def valid
    %w[MARKET_POSTGRES_PASSWORD PUBLIC_API_TOKEN MANUAL_PROVIDER_TOKEN NILX_BROWSER_HANDOFF_TOKEN TRADING_LAB_SERVICE_TOKEN].to_h { |name| [name, "x" * 40] }.merge("PARTNER_LOOKUP_TOKEN" => "p" * 40, "CHANNEL_ASSERTION_SECRET" => "c" * 40)
  end
end
