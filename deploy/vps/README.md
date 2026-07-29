# VPS deployment

This directory deploys the provider-agnostic `0xda-market` application workloads to the shared Ubuntu VPS.

The public edge is **not** part of this product deployment. Caddy, TLS state, public ports `80/443`, and host/path routing are owned by [`0x0sky/infra`](https://github.com/0x0sky/infra).

The client bot is deployed independently from `0xda-market/0xda-market-bot`. Both workloads attach to the external Docker network `nilx-edge` and expose stable internal aliases consumed by the shared edge.

## Ownership boundary

`0xda-market` owns:

- the API image and release lifecycle;
- the `api:10000` network contract;
- database migrations and application health;
- `mcp-control` integration;
- public route verification after deployment.

`0x0sky/infra` owns:

- Caddy and automatic TLS;
- public TCP ports `80` and `443`;
- the `nilx-edge` network contract;
- `${DOMAIN}` routing;
- `/bot/*` routing to `market-bot:10000`;
- shared-edge deployment and rollback.

A product deployment must never create, remove, or reconfigure the shared Caddy service.

## Current deployment contract

Automated deployment remains development-only:

| GitHub environment | Source branch | Runtime directory | Database |
| --- | --- | --- | --- |
| `development` | `master` | `environments/development` | test Supabase |

Production activation requires a separately reviewed release and compatible core/bot pair.

## VPS layout

```text
/opt/0xda-market/
  environments/
    development/
      current -> releases/<sha>
      releases/
      shared/.env
    production/
      current -> releases/<sha>
      releases/
      shared/.env

/opt/0xda-market-bot/
  environments/
    development/
      current -> releases/<sha>
      releases/
      shared/.env

/opt/infra/
  environments/
    development/
      current -> releases/<sha>
      releases/
      shared/.env

/opt/0xda-market-runtime/
  active-environment
```

## GitHub environment

Required secrets:

- `VPS_HOST`
- `VPS_USER=deploy`
- `VPS_SSH_PRIVATE_KEY`

Repository variables:

- `VPS_DEPLOY_PATH=/opt/0xda-market`

The SSH port is fixed to `22022` by the workflow.

## Runtime file

The development runtime file is:

```text
/opt/0xda-market/environments/development/shared/.env
```

Start from `.env.example`:

```env
DEPLOY_ENV=development
DOMAIN=0xda-market.nilx.one
MARKET_EDGE_NETWORK=nilx-edge
EDGE_OWNER=infra
DATABASE_URL=<development Supabase URL>
PUBLIC_API_TOKEN=<development token>
MANUAL_PROVIDER_TOKEN=<development token>
VERIFY_PUBLIC_HTTPS=1
```

`EDGE_OWNER=infra` is a migration safety gate. Activation fails before Compose mutation unless the standalone shared edge has already been cut over and verified.

Protect runtime files:

```sh
chown deploy:deploy /opt/0xda-market/environments/*/shared/.env
chmod 0600 /opt/0xda-market/environments/*/shared/.env
```

## Deployment behavior

After green `CI`, a push to `master` stages or refreshes development.

- staging builds and validates the release without changing the active stack;
- activation requires `EDGE_OWNER=infra`;
- only `api` and `mcp-control` belong to this Compose project;
- `docker compose up --remove-orphans` cannot remove the standalone infra Caddy because it uses a different Compose project;
- application health and public HTTPS remain deployment gates;
- failed activation attempts to restore the previous application release.

The shared edge forwards:

- `${DOMAIN}/bot/*` to `market-bot:10000`, stripping `/bot`;
- all other `${DOMAIN}` requests to `api:10000`.

That routing contract is canonical in `0x0sky/infra`, not in this repository.

## Migration gate

Do not merge the edge-extraction PR until all of the following are true:

1. `0x0sky/infra` edge contract is merged and green;
2. its `validate` workflow succeeds against the VPS;
3. an explicitly authorized `activate` cutover succeeds;
4. `mind.nilx.one`, `${DOMAIN}/health`, and `${DOMAIN}/bot/health` pass public verification;
5. the core shared `.env` contains `EDGE_OWNER=infra`.

Before those conditions, the legacy Caddy remains the active edge.

## Verification

Run the product verifier after deployment and every VPS reboot:

```sh
sudo -u deploy \
  bash /opt/0xda-market/environments/development/current/deploy/vps/verify.sh
```

It validates:

- API and bot container health;
- `nilx-edge` membership;
- local bot health;
- public API and bot routes through the independently managed infra edge.

Basic public checks:

```sh
curl -i https://0xda-market.nilx.one/health
curl -i https://0xda-market.nilx.one/bot/health
```

## Safety gates

- Keep `REGISTER_TELEGRAM_WEBHOOK=0` until local and public health checks pass.
- Keep application host ports bound to loopback; public access must pass through the shared edge.
- Do not activate production until its database, tokens, bot pairing, CI, and recovery plan are reviewed.
- Do not merge this migration before the infra edge cutover.
- Do not delete the legacy Caddy volumes; `0x0sky/infra` adopts them to preserve TLS state.
