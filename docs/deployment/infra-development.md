# Development Core deployment via Infra

Core development runs privately on `edge-prod-1` over the existing
`nilx-edge` Docker network. Only the Telegram TEST bot consumes its API;
there is **no public Core development hostname**.

## Ownership and rollout

| Component | Owner | Infra workload | Health |
| --- | --- | --- | --- |
| Core API + database migrations | `0xda-market/core` | `market-api-development` | HTTP `/health` on port 10000 |
| FX refresh loop | `0xda-market/core` | `market-fx-development` | Running process |
| Market price refresh loop | `0xda-market/core` | `market-prices-development` | Running process |
| Telegram TEST bot | `0xda-market/telegram-bot` | `market-bot-test` | HTTP `/health` on port 10000 |

Production workloads and their PostgreSQL instance are never replaced by
development activation. The development database must be the independent
`0xda-market-test` **Supabase PostgreSQL** project.

After the Infra contract PR has been merged, the Core workflow
`.github/workflows/deploy-vps.yml` is **manual-only** and runs only from
`master`, after successful exact-HEAD push Full CI. The workflow builds
`ghcr.io/0xda-market/core` once and passes the immutable digest to Infra.
Infra encrypts nothing on behalf of Core: Core obtains a per-request public
recipient from Infra, encrypts only allowlisted credentials, and asks Infra
to activate. Core waits for Infra's success before continuing; the API
and its migrations must become healthy before the workers activate.

## Credentials

In `0xda-market/core` GitHub Environment **development**, configure:

- Secrets: `DATABASE_URL` (complete Session pooler or direct Supabase
  PostgreSQL URI), `PUBLIC_API_TOKEN`, `MANUAL_PROVIDER_TOKEN`.
- Secret or appropriately scoped organization secret: `INFRA_DEPLOY_TOKEN`,
  with permission to read recipient artifacts and dispatch to
  `aiaiaiai-org/infra`.

The source credentials must **not** be copied to `infra` GitHub secrets.
The target `aiaiaiai-org/infra` Environment **edge-prod-1** owns only
SSH and GHCR pull credentials. It must have `GHCR_PULL_USER` and
`GHCR_PULL_TOKEN` with `read:packages` on the Core image.
Development Core does not use the older `SSH_*` repository credentials.

`PUBLIC_API_TOKEN` **must exactly match** the Telegram bot's
`development` Environment secret `MARKET_API_TOKEN`. Changing either
requires reactivation of the affected workload. The Telegram webhook
secret and Bot API token are separate and are not changed by Core.

The explicit contract sets development profitability defaults to 100 bps
minimum margin and 100 bps supply buffer, with no configured fixed or
variable settlement costs. Verify the assumptions before market activity.
Optional mock-payment configuration remains disabled. Core's start command
checks its database target and applies migrations before serving traffic.

## Activation

1. Merge and verify Infra contracts/CI first, without triggering deployment.
2. Set the Core development secrets listed above; double-check that
   `DATABASE_URL` points to the **test Supabase** project.
3. Ensure that the `GHCR_PULL_TOKEN` in Infra can read
   `ghcr.io/0xda-market/core`.
4. Merge Core after green Full CI. Allow the new `master` push Full CI
   to complete successfully.
5. Explicitly run
   `0xda-market/core → Actions → Deploy development via infra → Run workflow`
   from `master`.
6. Verify each named `Deploy market-*-development` activation in
   `aiaiaiai-org/infra`. Confirm API migration/health first, then
   successful worker starts. Review worker logs for real update success:
   process liveness is not proof of successful FX/pricing refresh.
7. Verify from inside the TEST bot container:

   ```sh
   sudo docker exec market-bot-test ruby -rnet/http -ruri \
     -e 'u=URI("http://market-api-development:10000/health"); puts Net::HTTP.get_response(u).code'
   ```

8. Verify `https://0xda-market.nilx.one/bot-test/health`, webhook
   delivery with `getWebhookInfo`, and the bot's `/start` command.
   The shared edge/Caddy is deployed separately and must already have
   the `/bot-test/*` route.

## Rollback and safety

Infra's container activation tracks a previous image and attempts to
restore it if a replacement fails health checks. Database migrations
are **not** rolled back by container rollback; review schema compatibility
before activation. A newly created development API has no previous
image to restore.

The former direct-SSH `deploy/vps` pipeline is no longer an active
development release path. Production Core deployment is frozen until
its own reviewed Infra contract and explicit activation are approved.
Do not dispatch `market-api-production` to work around development
failures. No secret values should appear in PRs, logs or tickets.

<!-- © 2026 aiaiaiai · aiaiaiai.org -->
