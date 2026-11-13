<!-- © 2026 aiaiaiai · aiaiaiai.org -->

# Production delivery

Production Core (`market-api-production`) is delivered by
`aiaiaiai-org/infra` from this repository's verified `master` builds. This
repository holds no infra credential, and infra holds none of Core's secrets
(infra `docs/automatic-delivery.md`, `docs/market-postgres-production.md`).

## What CI publishes

After `unit`, `test` and `docker` pass on a `master` push, the
`publish-production` job in `.github/workflows/ci.yml` runs in this
repository's **production** Environment and publishes, with build provenance
attestations:

- `ghcr.io/0xda-market/core:<full SHA>`: the image;
- `ghcr.io/0xda-market/core:<full SHA>.secrets`: one `age`-encrypted file for
  `edge-prod-1`'s published `encryptionRecipient`, holding exactly the names
  infra's `market-api-production` contract maps (the job refuses to publish
  otherwise):

| Name | Source |
| --- | --- |
| `MARKET_POSTGRES_PASSWORD` | Environment secret; also creates `market-postgres-production` |
| `MARKET_DATABASE_URL` | derived by the job: `postgres://market:<password, URL-encoded>@market-postgres-production:1927/market` |
| `PUBLIC_API_TOKEN` | Environment secret |
| `MANUAL_PROVIDER_TOKEN` | Environment secret |
| `NILX_BROWSER_HANDOFF_TOKEN` | Environment secret, the same value as 0x1 Identity's |
| `TRADING_LAB_SERVICE_TOKEN` | Environment secret, at least 32 bytes; the same value as the production Telegram bot's `TRADING_LAB_TOKEN` |

`DatabaseTarget` refuses a production URL without a password, so the URL is
derived from the one password: they cannot drift.

## Trading Lab

Trading Lab (`0xda-market/trading-lab`) is part of production Market and runs
on its capacity. Its infra workloads (`market-trading-lab` and its collectors)
take `MARKET_DATABASE_URL` and `TRADING_LAB_SERVICE_TOKEN` from this envelope
through `runtime.secretsFrom: market-api-production`, so Trading Lab holds no
production secret and no separate database password. It keeps its tables in
its own schema, `trading_lab`, inside the `market` database; Core's migrations
use the `market` schema and never touch it. Development Trading Lab has no
database.

## Turning it on (owner)

1. Fill the **production** Environment's five secrets. Never commit, print or
   paste a value. The password is at least 24 characters, the handoff secret at
   least 32 bytes.
2. Set the repository variable `PRODUCTION_DELIVERY=enabled`. Until then the
   job does not run and `master` CI does not depend on production secrets.
3. Give `aiaiaiai-org/infra` **Read** on the `core` package (Package settings →
   Manage Actions access).
4. Infra then adds `delivery` to `market-api-production` and `secretsFrom` to
   `market-postgres-production`, and brings the database up first
   (`docs/market-postgres-production.md` in infra).

The legacy `deploy-vps.yml` production path stays frozen.
