# FX rate refresh

Client prices and broker supply economics remain canonical in USDT. Currency conversion starts with a provider snapshot before any client-facing presentation rule runs.

```text
Coinbase Data API
  -> provider adapter
  -> complete USDT-per-unit snapshot
  -> append-only currency product prices
  -> freshness gate
  -> exact conversion
  -> client price presentation
```

## Step 0: acquire and persist rates

The initial adapter uses Coinbase's unauthenticated [`GET /v2/exchange-rates`](https://docs.cdp.coinbase.com/coinbase-app/track-apis/exchange-rates) endpoint with `currency=USDT`. Coinbase returns target-currency units per one USDT. The adapter inverts each requested value because the existing core contract stores `amount_usdt` as USDT paid per one currency unit.

The provider-neutral refresh service requires every configured non-base currency in one response. It appends the complete set through the existing pricing revision lock with an auditable source such as `fx:coinbase`; a missing or invalid rate appends nothing. One concurrency conflict is retried against the same observed snapshot.

The standalone `fx-refresh` process runs immediately and then every five minutes by default. It owns no HTTP API and no user authorization. Its only write is the append-only currency price batch.

## Freshness and failure behavior

The API reads the last persisted snapshot and never calls an FX provider in a client request. A failed refresh keeps the previous snapshot available until `FX_RATE_MAX_AGE_SECONDS`, one hour by default. After that TTL, non-USDT conversion is rejected until a fresh complete snapshot is stored. USDT remains fixed at `1` and does not depend on the provider.

This is intentionally fail-closed: a stale display rate cannot silently change market margin or normalize broker supply at an obsolete price. Existing broker inventory remains listed but is not executable when its currency rate is stale.

## Configuration

| Variable | Default | Meaning |
| --- | ---: | --- |
| `FX_RATE_PROVIDER` | `coinbase` | Concrete adapter selected by the refresh runtime |
| `FX_RATE_REFRESH_INTERVAL_SECONDS` | `300` | Normal refresh cadence |
| `FX_RATE_RETRY_INTERVAL_SECONDS` | `60` | Retry cadence after provider or persistence failure |
| `FX_RATE_REQUEST_TIMEOUT_SECONDS` | `10` | Upstream connect and read timeout |
| `FX_RATE_MAX_AGE_SECONDS` | `3600` | Maximum accepted persisted rate age |

Adding another provider requires a new outward adapter that returns the same provider-neutral rate snapshot. It must not change pricing, localization, listing or WebApp contracts.
