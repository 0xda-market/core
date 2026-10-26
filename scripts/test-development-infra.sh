#!/usr/bin/env bash
# © 2026 aiaiaiai · aiaiaiai.org
set -Eeuo pipefail

workflow=.github/workflows/deploy-vps.yml
script=scripts/dispatch-development-workload.sh

grep -Fq 'workflow_dispatch:' "$workflow"
grep -Fq 'actions/workflows/ci.yml/runs?event=push&head_sha=$GITHUB_SHA' "$workflow"
grep -Fq 'market-api-development' "$workflow"
grep -Fq 'market-fx-development' "$workflow"
grep -Fq 'market-prices-development' "$workflow"
grep -Fq 'needs: [package, activate_api]' "$workflow"
grep -Fq 'ghcr.io/0xda-market/core:development-' "$workflow"
grep -Fq 'secrets.DATABASE_URL' "$workflow"
grep -Fq 'secrets.PUBLIC_API_TOKEN' "$workflow"
grep -Fq 'secrets.MANUAL_PROVIDER_TOKEN' "$workflow"
grep -Fq 'secrets.NILX_BROWSER_HANDOFF_TOKEN' "$workflow"
grep -Fq 'names=(DATABASE_URL PUBLIC_API_TOKEN MANUAL_PROVIDER_TOKEN NILX_BROWSER_HANDOFF_TOKEN)' "$script"
grep -Fq 'secrets.INFRA_DEPLOY_TOKEN' "$workflow"
! grep -Eq '\bSSH_(HOST|USER|PRIVATE_KEY)\b' "$workflow"

grep -Fq 'issue-workload-recipient' "$script"
grep -Fq 'age --armor' "$script"
grep -Fq 'market-postgres-production' "$script"
grep -Fq 'url.hostname.endswith(".supabase.com")' "$script"
grep -Fq 'Deploy $WORKLOAD' "$script"
grep -Fq 'Infra activation failed.' "$script"
! grep -Fq 'GHCR_PULL_TOKEN=' "$script"

# Verify the cross-repository correlation contract used by the stack orchestrator.
grep -Fq 'run-name: Deploy Market Core ${{ inputs.request_id || github.sha }}' "$workflow"
grep -Fq '      request_id:' "$workflow"
grep -Fq '        required: false' "$workflow"
grep -Fq '        type: string' "$workflow"
[[ "$(grep -Fc -- '--arg request_id "$GITHUB_RUN_ID"' "$script")" -eq 2 ]]
grep -Fq '{workload: $workload, image: $image, secrets_age: $secrets_age, request_id: $request_id}' "$script"
grep -Fq 'title="Deploy $WORKLOAD / $GITHUB_RUN_ID"' "$script"

# Exercise the actual deploy-run jq selector with unrelated, stale and
# cross-branch workflow runs. Never dispatch or access GitHub from this test.
deploy_selector="$(awk '
  index($0, "--argjson baseline \"$deploy_baseline\"") { selecting = 1; next }
  selecting && index($0, "<<<\"$response\")") { exit }
  selecting { print }
' "$script")"
[[ -n "$deploy_selector" ]]

mock_runs='{"workflow_runs":[
  {"id":99,"display_title":"Deploy market-api-development / 4242","head_branch":"master","conclusion":"success"},
  {"id":101,"display_title":"Deploy market-api-development / 9999","head_branch":"master","conclusion":"success"},
  {"id":102,"display_title":"Deploy market-api-development / 4242","head_branch":"feature/other","conclusion":"success"},
  {"id":103,"display_title":"Deploy market-fx-development / 4242","head_branch":"master","conclusion":"success"},
  {"id":104,"display_title":"Deploy market-api-development / 4242","head_branch":"master","conclusion":"success"},
  {"id":105,"display_title":"Deploy market-prices-development / 4242","head_branch":"master","conclusion":"success"},
  {"id":106,"display_title":"Deploy market-api-development / 4242","head_branch":"master","conclusion":"failure"}
]}'
matched="$(jq -c --arg title 'Deploy market-api-development / 4242' \
  --argjson baseline 100 "$deploy_selector" <<<"$mock_runs")"
[[ "$(jq -r '.id' <<<"$matched")" == 106 ]]
[[ "$(jq -r '.conclusion' <<<"$matched")" == failure ]]
[[ -z "$(jq -c --arg title 'Deploy market-api-development / 4243' \
  --argjson baseline 100 "$deploy_selector" <<<"$mock_runs")" ]]
[[ -z "$(jq -c --arg title 'Deploy market-api-development / 4242' \
  --argjson baseline 106 "$deploy_selector" <<<"$mock_runs")" ]]

bash -n "$script"
echo "development Core infra delivery contract verified"
