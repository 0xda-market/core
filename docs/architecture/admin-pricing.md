# Administrator pricing

Pricing remains a provider- and channel-neutral core capability. Telegram commands, Telegram Mini App, a website and future clients must all use the same append-only price ledger and administrator authorization.

## Data model

`market.product_prices` is the authoritative append-only history. A row contains the catalog SKU, positive USDT amount, source, internal editor UUID and application time. The current product snapshot is maintained from the latest history row; historical rows are never updated or deleted by the pricing API.

The monotonic pricing revision is the greatest persisted price-row ID. It represents the exact ledger state used to build an administrator proposal.

## Proposal and application

```text
GET /v1/admin/prices/proposal
  -> active products and currencies
  -> current and previous amounts
  -> meta.revision
  -> meta.generated_at

POST /v1/admin/prices
  revision: <proposal revision>
  prices: [one or more changed prices]
```

Every submitted price is validated against the catalog before persistence. The store then acquires one revision lock and compares the submitted revision with the current ledger revision.

- Memory uses one mutex-protected atomic append.
- PostgreSQL uses one transaction and transaction-scoped advisory lock.
- A stale revision raises `concurrency_conflict` before any price is appended.
- A valid application appends the submitted batch or nothing; unchanged and currently unpriced catalog rows need not be repeated.

For marketable products, the applied administrator amount is a commercial client-price floor. Buyer catalog and quote surfaces use the greater of that amount and the minimum profitable price derived from the cheapest broker listing that can execute the requested quantity. An expensive outlier listing does not move the market while cheaper executable liquidity remains available.

The append-only pricing ledger remains unchanged. Profitability is computed at the buyer boundary and revalidated while reserving inventory; an administrator price can therefore remain stable while broker supply changes without permitting a loss-making order.

Existing command adapters may omit the revision for backward compatibility. Reviewed interactive workspaces must preserve and submit the explicit proposal revision.

Every JSON API `POST` response includes a top-level operation `status`: `ok` for a successful response and `error` for a rejected response. Resource lifecycle status remains under `data.attributes.status`; the top-level field only reports the request outcome.

## History

`GET /v1/admin/prices/history` returns recent append-only rows ordered newest first, including editor and application time. Access requires the persisted internal administrator UUID. Channel-specific identities are resolved before the request reaches core.

## Boundaries

Pricing does not own Telegram copy, browser state, wallets or settlement. Currency exchange values use the same pricing model because currencies are non-marketable catalog products whose amount means USDT paid per unit.
