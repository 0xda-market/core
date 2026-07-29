#!/usr/bin/env bash
set -Eeuo pipefail

core_root="${CORE_DEPLOY_PATH:-/opt/0xda-market}"
bot_root="${BOT_DEPLOY_PATH:-/opt/0xda-market-bot}"
runtime_root="${VPS_RUNTIME_PATH:-/opt/0xda-market-runtime}"
state_file="$runtime_root/active-environment"
verify_systemd="${VERIFY_SYSTEMD:-1}"
verify_public_https="${VERIFY_PUBLIC_HTTPS:-1}"
expected_edge_network="nilx-edge"

fail() {
  echo "verification failed: $*" >&2
  exit 1
}

read_env_value() {
  local file="$1"
  local key="$2"
  sed -n "s/^${key}=//p" "$file" | tail -n 1
}

current_release() {
  local root="$1"
  local environment="$2"
  readlink -f "$root/environments/$environment/current" 2>/dev/null || true
}

compose() {
  local release="$1"
  local env_file="$2"
  shift 2
  docker compose \
    --file "$release/deploy/vps/compose.yaml" \
    --env-file "$env_file" \
    --project-directory "$release/deploy/vps" \
    "$@"
}

container_for() {
  local release="$1"
  local env_file="$2"
  local service="$3"
  compose "$release" "$env_file" ps --quiet "$service"
}

check_container() {
  local label="$1"
  local container_id="$2"
  local require_health="$3"
  local running restart_policy log_driver max_size max_file health

  [[ -n "$container_id" ]] || fail "$label container is missing"

  running="$(docker inspect --format '{{.State.Running}}' "$container_id")"
  [[ "$running" == "true" ]] || fail "$label container is not running"

  restart_policy="$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$container_id")"
  [[ "$restart_policy" == "unless-stopped" ]] || fail "$label restart policy is $restart_policy"

  log_driver="$(docker inspect --format '{{.HostConfig.LogConfig.Type}}' "$container_id")"
  [[ "$log_driver" == "json-file" ]] || fail "$label log driver is $log_driver"

  max_size="$(docker inspect --format '{{index .HostConfig.LogConfig.Config "max-size"}}' "$container_id")"
  max_file="$(docker inspect --format '{{index .HostConfig.LogConfig.Config "max-file"}}' "$container_id")"
  [[ "$max_size" == "10m" && "$max_file" == "3" ]] || \
    fail "$label log rotation is max-size=$max_size max-file=$max_file"

  if [[ "$require_health" == "1" ]]; then
    health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_id")"
    [[ "$health" == "healthy" ]] || fail "$label health is $health"
  fi

  echo "ok: $label"
}

check_network_membership() {
  local label="$1"
  local container_id="$2"
  local networks

  networks="$(docker inspect --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' "$container_id")"
  grep -qx "$expected_edge_network" <<<"$networks" || \
    fail "$label is not attached to $expected_edge_network"

  echo "ok: $label network=$expected_edge_network"
}

[[ -f "$state_file" ]] || fail "active environment marker is missing: $state_file"
active_environment="$(<"$state_file")"
case "$active_environment" in
  development|production) ;;
  *) fail "unsupported active environment: $active_environment" ;;
esac

core_release="$(current_release "$core_root" "$active_environment")"
bot_release="$(current_release "$bot_root" "$active_environment")"
[[ -n "$core_release" && -d "$core_release/deploy/vps" ]] || fail "core release is not staged"
[[ -n "$bot_release" && -d "$bot_release/deploy/vps" ]] || fail "bot release is not staged"

core_env="$core_root/environments/$active_environment/shared/.env"
bot_env="$bot_root/environments/$active_environment/shared/.env"
[[ -f "$core_env" ]] || fail "core runtime file is missing: $core_env"
[[ -f "$bot_env" ]] || fail "bot runtime file is missing: $bot_env"
[[ "$(read_env_value "$core_env" DEPLOY_ENV)" == "$active_environment" ]] || fail "core DEPLOY_ENV mismatch"
[[ "$(read_env_value "$bot_env" DEPLOY_ENV)" == "$active_environment" ]] || fail "bot DEPLOY_ENV mismatch"
[[ "$(read_env_value "$core_env" EDGE_OWNER)" == "infra" ]] || fail "core EDGE_OWNER must be infra"

core_edge_network="$(read_env_value "$core_env" MARKET_EDGE_NETWORK)"
bot_edge_network="$(read_env_value "$bot_env" MARKET_EDGE_NETWORK)"
[[ -z "$core_edge_network" || "$core_edge_network" == "$expected_edge_network" ]] || \
  fail "core MARKET_EDGE_NETWORK must be $expected_edge_network"
[[ -z "$bot_edge_network" || "$bot_edge_network" == "$expected_edge_network" ]] || \
  fail "bot MARKET_EDGE_NETWORK must be $expected_edge_network"

if [[ "$verify_systemd" == "1" ]]; then
  systemctl is-enabled --quiet docker || fail "Docker is not enabled at boot"
  systemctl is-active --quiet docker || fail "Docker is not active"
  echo "ok: Docker boot service"
fi

docker network inspect "$expected_edge_network" >/dev/null 2>&1 || \
  fail "Docker network is missing: $expected_edge_network"

compose "$core_release" "$core_env" config --quiet
compose "$bot_release" "$bot_env" config --quiet

api_container="$(container_for "$core_release" "$core_env" api)"
bot_container="$(container_for "$bot_release" "$bot_env" bot)"

check_container "core API" "$api_container" 1
check_container "client bot" "$bot_container" 1

check_network_membership "core API" "$api_container"
check_network_membership "client bot" "$bot_container"

curl --fail --silent --show-error --retry 3 --retry-connrefused \
  http://127.0.0.1:10001/health >/dev/null
echo "ok: local bot health"

if [[ "$verify_public_https" == "1" ]]; then
  domain="$(read_env_value "$core_env" DOMAIN)"
  [[ -n "$domain" ]] || fail "DOMAIN is missing from the core runtime file"

  curl --fail --silent --show-error --retry 3 --retry-all-errors \
    "https://${domain}/health" >/dev/null
  curl --fail --silent --show-error --retry 3 --retry-all-errors \
    "https://${domain}/bot/health" >/dev/null
  echo "ok: public HTTPS health through 0x0sky/infra edge"
fi

printf 'VPS verification passed: environment=%s core=%s bot=%s network=%s edge-owner=infra\n' \
  "$active_environment" "$(basename "$core_release")" "$(basename "$bot_release")" "$expected_edge_network"
