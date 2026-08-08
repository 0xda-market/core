#!/usr/bin/env bash
set -Eeuo pipefail

previous_release="${1:-}"
shared_env="${2:-}"

if [[ -z "$previous_release" || ! -d "$previous_release/deploy/vps" ]]; then
  echo "A previous release with deploy/vps is required for rollback" >&2
  exit 1
fi

previous_vps="$previous_release/deploy/vps"

if [[ -n "$shared_env" ]]; then
  test -f "$shared_env"
  ln -sfn "$shared_env" "$previous_vps/.env"
fi

test -f "$previous_vps/.env"
test -f "$previous_vps/compose.yaml"

services="$(cd "$previous_vps" && docker compose config --services)"

wait_for_api() {
  local container health

  container="$(cd "$previous_vps" && docker compose ps --quiet api)"
  if [[ -z "$container" ]]; then
    echo "Rollback did not create the previous api container" >&2
    return 1
  fi

  for _ in $(seq 1 36); do
    health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null || true)"
    case "$health" in
      healthy)
        return 0
        ;;
      unhealthy)
        echo "Previous api became unhealthy during rollback" >&2
        (cd "$previous_vps" && docker compose logs --tail 200 api) >&2 || true
        return 1
        ;;
    esac
    sleep 5
  done

  echo "Previous api did not become healthy during rollback" >&2
  (cd "$previous_vps" && docker compose logs --tail 200 api) >&2 || true
  return 1
}

if grep -qx caddy <<<"$services"; then
  # Releases from before edge decoupling own ports 80/443. The current VPS edge
  # is infra-owned, so invoking their full deploy script would race the shared
  # proxy and fail with "port is already allocated". Restore only the product
  # API; the infra edge continues routing to 127.0.0.1:10000.
  echo "Rolling back legacy release without its retired Caddy service"
  (
    cd "$previous_vps"
    docker compose up --detach --no-deps api
  )
  wait_for_api
  echo "Legacy api rollback is healthy behind the infra-owned edge"
  exit 0
fi

# Edge-decoupled releases can use their own activation contract safely.
DEPLOY_MODE=activate bash "$previous_vps/deploy.sh"
