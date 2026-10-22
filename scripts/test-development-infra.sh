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
grep -Fq 'secrets.INFRA_DEPLOY_TOKEN' "$workflow"
! grep -Eq '\bSSH_(HOST|USER|PRIVATE_KEY)\b' "$workflow"

grep -Fq 'issue-workload-recipient' "$script"
grep -Fq 'age --armor' "$script"
grep -Fq 'market-postgres-production' "$script"
grep -Fq 'url.hostname.endswith(".supabase.com")' "$script"
grep -Fq 'Deploy $WORKLOAD' "$script"
grep -Fq 'Infra activation failed.' "$script"
! grep -Fq 'GHCR_PULL_TOKEN=' "$script"

bash -n "$script"
echo "development Core infra delivery contract verified"
