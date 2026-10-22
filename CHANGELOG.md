# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Execution-aware client pricing and a locked pre-order profitability gate that
  prevents marketplace reservations below the configured net margin.
- Issuer denominations: a non-fiat registry with `seeds` (₴€£) as the first
  entry, an append-only price history limited to eligible game goods, and
  read/admin JSON routes. The registry stays outside FX and balances.
- Issuer orders: purchases paid in an issuer denomination, with a snapshotted
  price and recipient, customer create/read/cancel routes, and a separately
  authenticated issuer API to claim, fulfil or reject. The recipient is found
  through issuer-asserted account links from the customer's channel account
  (for example a messenger account), which only the issuer can publish or withdraw. The
  market holds no balance and never settles the denomination itself.

### Fixed

- `POST /v1/admin/prices` reports the revision its own batch produced instead of
  re-reading it after commit, where a concurrent price refresh could advance it
  and let the next admin write skip the stale-revision check.

## [0.1.0] - 2026-07-19

### Added

- Provider-agnostic intent, quote and order lifecycle with synchronous,
  deferred and idempotent execution.
- PostgreSQL persistence, transactional migrations and a durable manual
  fulfillment queue.
- Authenticated public and operator JSON APIs, health reporting and Telegram
  identity authentication with provider-independent user UUIDs.
- Database-backed product catalog, append-only USDT price history and current
  price snapshots with editor audit data.
- Product localization records with `en_US` as the canonical fallback and a
  complete `uk_UA` catalog.
- Separate Render test and production environments sourced from `master` and
  `release` respectively.

### Changed

- **Breaking:** replaced the `premium_9m` SKU with `premium_12m`; existing
  price history is migrated to the new SKU.
- Moved full product names and Telegram button labels out of `products` and
  into `product_localizations`.
- Price writes now attribute editors to internal user UUIDs instead of using
  Telegram IDs as domain identifiers.

### Fixed

- Recovered stale PostgreSQL connections and aligned Render environment names,
  variables and deployment branches.
- Retained a temporary, read-only-compatible copy of legacy catalog columns so
  the previous core can be redeployed during the v0.1 rollback window.

### Security

- Enforced bearer authentication on public and operator APIs and persisted
  admin-role authorization for privileged operations.

[Unreleased]: https://github.com/0xda-market/core/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/0xda-market/core/releases/tag/v0.1.0
