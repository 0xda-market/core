#!/usr/bin/env bash
# © 2026 aiaiaiai · aiaiaiai.org
set -Eeuo pipefail
umask 077

INFRA_REPOSITORY=aiaiaiai-org/infra
case "${WORKLOAD:-}" in
  market-api-development)
    names=(DATABASE_URL PUBLIC_API_TOKEN MANUAL_PROVIDER_TOKEN)
    ;;
  market-fx-development|market-prices-development)
    names=(DATABASE_URL)
    ;;
  *)
    echo "::error::Unknown development workload." >&2
    exit 1
    ;;
esac

[[ "${GITHUB_REF:-}" == refs/heads/master ]] || { echo "::error::Master only." >&2; exit 1; }
[[ "${IMAGE_REF:-}" =~ ^ghcr[.]io/0xda-market/core@sha256:[0-9a-f]{64}$ ]] || {
  echo "::error::Expected immutable Core digest." >&2
  exit 1
}
[[ -n "${GH_TOKEN:-}" ]] || { echo "::error::Missing INFRA_DEPLOY_TOKEN." >&2; exit 1; }

for name in "${names[@]}"; do
  value="${!name:-}"
  [[ -n "$value" && "$value" != *$'\r'* && "$value" != *$'\n'* ]] || {
    echo "::error::Missing or multiline development credential $name." >&2
    exit 1
  }
done

# Never let development use the self-hosted production database.
python3 - <<'PY'
from urllib.parse import urlsplit
import os
url = urlsplit(os.environ["DATABASE_URL"])
if url.scheme not in ("postgres", "postgresql") or not url.username or not url.password:
    raise SystemExit("::error::DATABASE_URL must be a complete PostgreSQL URI.")
if not url.hostname or not url.hostname.endswith(".supabase.com"):
    raise SystemExit("::error::Development database must use isolated Supabase PostgreSQL.")
if url.hostname == "market-postgres-production":
    raise SystemExit("::error::Production database is forbidden.")
PY

workflow=issue-workload-recipient.yml
runs_endpoint="repos/$INFRA_REPOSITORY/actions/workflows/$workflow/runs"
baseline="$(gh api --method GET "$runs_endpoint?event=repository_dispatch&per_page=1" --jq '.workflow_runs[0].id // 0')"
[[ "$baseline" =~ ^[0-9]+$ ]]
jq -nc --arg workload "$WORKLOAD" --arg request_id "$GITHUB_RUN_ID" '
  {event_type: "issue-workload-recipient", client_payload:
    {workload: $workload, request_id: $request_id}}
' | gh api --method POST "repos/$INFRA_REPOSITORY/dispatches" --input -

title="Recipient $WORKLOAD / $GITHUB_RUN_ID"
recipient_run=""
for attempt in $(seq 1 48); do
  response="$(gh api --method GET "$runs_endpoint?event=repository_dispatch&per_page=100")"
  match="$(jq -c --arg title "$title" --argjson baseline "$baseline" '
    [.workflow_runs[] | select(.id > $baseline and .display_title == $title
      and .head_branch == "master")] | sort_by(.id) | last // empty
  ' <<<"$response")"
  if [[ -n "$match" ]]; then
    status="$(jq -r .status <<<"$match")"
    conclusion="$(jq -r '.conclusion // ""' <<<"$match")"
    if [[ "$status" == completed ]]; then
      [[ "$conclusion" == success ]] || { echo "::error::Recipient issuance failed." >&2; exit 1; }
      recipient_run="$(jq -r .id <<<"$match")"
      break
    fi
  fi
  sleep 10
done
[[ -n "$recipient_run" ]] || { echo "::error::Recipient issuance timed out." >&2; exit 1; }

recipient_dir="$RUNNER_TEMP/market-core-recipient"
install -d -m 0700 "$recipient_dir"
source_file="$RUNNER_TEMP/market-core-source.env"
encrypted_file="$RUNNER_TEMP/market-core-source.age"
trap 'rm -f "$source_file" "$encrypted_file"; rm -rf "$recipient_dir"' EXIT
gh run download "$recipient_run" --repo "$INFRA_REPOSITORY" \
  --name "recipient-$WORKLOAD-$GITHUB_RUN_ID" --dir "$recipient_dir"
recipient_path="$recipient_dir/recipient.pub"
test -s "$recipient_path"
test "$(wc -l < "$recipient_path")" -eq 1
grep -Eq '^ssh-(ed25519|rsa) [A-Za-z0-9+/=]+( .*)?$' "$recipient_path"
ssh-keygen -lf "$recipient_path" >/dev/null

{
  for name in "${names[@]}"; do
    printf '%s=%s\n' "$name" "${!name}"
  done
} > "$source_file"

sudo apt-get update -qq
sudo apt-get install -y -qq age
age --armor --recipient "$(cat "$recipient_path")" --output "$encrypted_file" "$source_file"
rm -f "$source_file"

deploy_runs="repos/$INFRA_REPOSITORY/actions/workflows/deploy-workload.yml/runs"
deploy_baseline="$(gh api --method GET "$deploy_runs?event=repository_dispatch&per_page=1" --jq '.workflow_runs[0].id // 0')"
[[ "$deploy_baseline" =~ ^[0-9]+$ ]]
jq -nc --arg workload "$WORKLOAD" --arg image "$IMAGE_REF" --arg request_id "$GITHUB_RUN_ID" --rawfile secrets_age "$encrypted_file" '
  {event_type: "deploy-workload", client_payload:
    {workload: $workload, image: $image, secrets_age: $secrets_age, request_id: $request_id}}
' | gh api --method POST "repos/$INFRA_REPOSITORY/dispatches" --input -

# The product job must wait for infra to finish. API migration/health is a
# hard prerequisite before the worker matrix can start.
title="Deploy $WORKLOAD / $GITHUB_RUN_ID"
deploy_run=""
for attempt in $(seq 1 90); do
  response="$(gh api --method GET "$deploy_runs?event=repository_dispatch&per_page=100")"
  match="$(jq -c --arg title "$title" --argjson baseline "$deploy_baseline" '
    [.workflow_runs[] | select(.id > $baseline and .display_title == $title
      and .head_branch == "master")] | sort_by(.id) | last // empty
  ' <<<"$response")"
  if [[ -n "$match" ]]; then
    status="$(jq -r .status <<<"$match")"
    conclusion="$(jq -r '.conclusion // ""' <<<"$match")"
    if [[ "$status" == completed ]]; then
      deploy_run="$(jq -r .id <<<"$match")"
      [[ "$conclusion" == success ]] || {
        echo "::error::Infra activation failed. See run $deploy_run." >&2
        exit 1
      }
      break
    fi
  fi
  sleep 10
done
[[ -n "$deploy_run" ]] || { echo "::error::Infra activation timed out." >&2; exit 1; }

{
  echo "### Development Core activation"
  echo "- Workload: $WORKLOAD"
  echo "- Source: $GITHUB_SHA"
  echo "- Image: $IMAGE_REF"
  echo "- Infra run: https://github.com/$INFRA_REPOSITORY/actions/runs/$deploy_run"
  echo "- Infra activation and health: success"
} >> "$GITHUB_STEP_SUMMARY"
