# VPS deployment

This directory deploys the provider-agnostic `0xda-market` application workloads to the shared Ubuntu VPS.

The public edge is **not** part of this product deployment. Caddy, TLS state, public ports `80/443`, and host/path routing are owned by [`0x0sky/infra`](https://github.com/0x0sky/infra).

The client bot is deployed independently from `0xda-market/telegram-bot`. Both workloads attach to the external Docker network `nilx-edge` and expose stable internal aliases consumed by the shared edge.

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

The repository has one `Deploy` workflow:

| Invocation | Source | GitHub environment | Runtime directory | Database |
| --- | --- | --- | --- | --- |
| merged pull request into `master` | exact merge commit | `development` | `environments/development` | test Supabase |
| manual dispatch | explicit branch, tag, or commit | `development` or `production` | matching environment directory | environment-owned |

Synchronizing an open pull request no longer creates a deployment run. Closing a
pull request without merging skips the deploy job. A manual production deployment
uses the protected `production` GitHub Environment and requires the compatible
core/bot release pair, runtime configuration, and recovery plan.

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
    production/
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

## GitHub environments

Configure every available deployment environment with these secrets:

- `SSH_HOST`
- `SSH_USER` (`deploy`)
- `SSH_PRIVATE_KEY`

And these variables:

- `SSH_DEPLOYMENT_PATH=/opt/0xda-market`
- `SSH_PORT=22022`

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

A merged pull request into `master` deploys its exact merge commit to
`development`. Pull-request CI events are not deployment triggers.

A manual run requires both:

- `source_ref`: branch, tag, or commit to deploy;
- `environment`: `development` or `production`.

The selected reference is resolved to an immutable commit before upload. Automatic
merge deployment stages development when it is inactive and refreshes it when it
is active. Manual dispatch force-activates the explicitly selected environment.
There is no separate environment-switch workflow.

- staging builds and validates the release without changing the active stack;
- activation requires `EDGE_OWNER=infra`;
- only `api` and `mcp-control` belong to this Compose project;
- `docker compose up --remove-orphans` cannot remove the standalone infra Caddy because it uses a different Compose project;
- application health and public HTTPS remain deployment gates;
- failed activation attempts to restore the previous application release;
- successful deployment publishes `deploy/vps-core-<environment>` on the exact release commit.

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
