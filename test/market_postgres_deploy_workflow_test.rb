# frozen_string_literal: true

require_relative "test_helper"
require "yaml"
require "open3"

class MarketPostgresDeployWorkflowTest < Minitest::Test
  WORKFLOW = File.expand_path("../.github/workflows/deploy-market-postgres.yml", __dir__)

  def setup
    @contents = File.read(WORKFLOW)
    @workflow = YAML.safe_load(@contents, aliases: false)
    @steps = @workflow.fetch("jobs").fetch("request").fetch("steps")
  end

  def test_every_inline_shell_step_has_valid_bash_syntax
    @steps.each do |step|
      next unless step["run"]

      _output, errors, result = Open3.capture3("bash", "-n", stdin_data: step.fetch("run"))
      assert result.success?, "#{step.fetch('name')}: #{errors}"
    end
  end

  def test_producer_does_not_need_a_persistent_recipient_variable
    refute_includes @contents, "INFRA_AGE_RECIPIENT"
    assert_includes @contents, "issue-workload-recipient"
    assert_includes @contents, "recipient-$WORKLOAD-$GITHUB_RUN_ID"
  end

  def test_recipient_request_precedes_password_access_and_fails_closed
    recipient_step = @steps.index { |step| step["name"] == "Obtain short-lived public recipient from infra" }
    encrypted_step = @steps.index { |step| step["name"] == "Encrypt scoped DB secret and request infra deployment" }

    refute_nil recipient_step
    refute_nil encrypted_step
    assert_operator recipient_step, :<, encrypted_step
    refute_includes @steps.fetch(recipient_step).to_s, "MARKET_POSTGRES_PASSWORD"
    assert_includes @steps.fetch(encrypted_step).to_s, "MARKET_POSTGRES_PASSWORD"
    assert_includes @steps.fetch(recipient_step).fetch("run"), "ssh-keygen -lf"
    assert_includes @steps.fetch(recipient_step).fetch("run"), '.head_branch == "master"'
  end
end
