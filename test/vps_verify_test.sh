#!/usr/bin/env bash
set -Eeuo pipefail

root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

core_root="$root/core"
bot_root="$root/bot"
runtime_root="$root/runtime"
commands="$root/bin"
mkdir -p "$commands" "$runtime_root"

for component in core bot; do
  release="$root/$component/environments/development/releases/release-1"
  mkdir -p "$release/deploy/vps" "$root/$component/environments/development/shared"
  printf 'DEPLOY_ENV=development\nMARKET_EDGE_NETWORK=nilx-edge\n' >"$root/$component/environments/development/shared/.env"
  if [[ "$component" == "core" ]]; then
    printf 'DOMAIN=example.invalid\nEDGE_OWNER=infra\n' >>"$root/$component/environments/development/shared/.env"
  fi
  : >"$release/deploy/vps/compose.yaml"
  ln -s "$release" "$root/$component/environments/development/current"
done
printf 'development\n' >"$runtime_root/active-environment"

cat >"$commands/systemctl" <<'SYSTEMCTL'
#!/usr/bin/env bash
exit 0
SYSTEMCTL

cat >"$commands/curl" <<'CURL'
#!/usr/bin/env bash
exit 0
CURL

cat >"$commands/docker" <<'DOCKER'
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$1" == "network" && "$2" == "inspect" && "$3" == "nilx-edge" ]]; then
  exit 0
fi

if [[ "$1" == "compose" ]]; then
  shift
  service=""
  while (($#)); do
    case "$1" in
      --file|--env-file|--project-directory)
        shift 2
        ;;
      config)
        exit 0
        ;;
      ps)
        shift
        [[ "${1:-}" == "--quiet" ]] && shift
        service="${1:-}"
        printf '%s-container\n' "$service"
        exit 0
        ;;
      exec)
        exit 0
        ;;
      *)
        shift
        ;;
    esac
  done
fi

if [[ "$1" == "inspect" ]]; then
  format="$3"
  case "$format" in
    *'.State.Running'*) printf 'true\n' ;;
    *'RestartPolicy.Name'*) printf 'unless-stopped\n' ;;
    *'LogConfig.Type'*) printf 'json-file\n' ;;
    *'max-size'*) printf '10m\n' ;;
    *'max-file'*) printf '3\n' ;;
    *'.State.Health'*) printf 'healthy\n' ;;
    *'.NetworkSettings.Networks'*) printf 'nilx-edge\n' ;;
    *) exit 1 ;;
  esac
  exit 0
fi

exit 1
DOCKER
chmod +x "$commands"/*

output="$({
  PATH="$commands:$PATH" \
  CORE_DEPLOY_PATH="$core_root" \
  BOT_DEPLOY_PATH="$bot_root" \
  VPS_RUNTIME_PATH="$runtime_root" \
  VERIFY_SYSTEMD=1 \
  VERIFY_PUBLIC_HTTPS=1 \
  bash "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/deploy/vps/verify.sh"
} 2>&1)"

grep -Fq 'ok: Docker boot service' <<<"$output"
grep -Fq 'ok: core API' <<<"$output"
grep -Fq 'ok: client bot' <<<"$output"
grep -Fq 'ok: core API network=nilx-edge' <<<"$output"
grep -Fq 'ok: client bot network=nilx-edge' <<<"$output"
grep -Fq 'ok: public HTTPS health through 0x0sky/infra edge' <<<"$output"
grep -Fq 'VPS verification passed: environment=development' <<<"$output"
grep -Fq 'network=nilx-edge edge-owner=infra' <<<"$output"

echo 'VPS verification test passed'
