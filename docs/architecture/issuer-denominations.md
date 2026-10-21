# Issuer denominations

An **issuer denomination** is a non-fiat unit of account owned by an external
issuer, for example a game currency. The market can price eligible goods in it
and present those prices. It does **not** own, mirror, value or move balances in
that unit.

The first registered denomination is `seeds` (display symbol `₴€£`), the
in-game currency of 0x1. Its naming and quantity forms are described in
[0x1 Special and Exclusive subscription catalog](0x1-subscription-catalog.md).

## Boundary

| Concern | Owner |
| --- | --- |
| Denomination code, symbol, scale, eligible product families | market (`market.denominations`) |
| Price of a product in the denomination | market (append-only `market.denomination_prices`) |
| Balances, debits, credits, entitlement grants | the issuer |

Denominations are separate from the fiat/FX model:

- a denomination is never a `market.products` currency row;
- its prices never enter `market.product_prices` or USDT valuation;
- there is no FX rate, USDT equivalence or client-side conversion;
- localized client price presentation does not apply to it.

The core code is issuer-neutral: `issuer` and product families are data. The
market and the issuer are not synchronous. Any later debit or grant flows
through an asynchronous, idempotent port with issuer confirmation, and the
browser cannot assert a balance or a successful debit.

## Eligibility: game goods only

A price row is accepted only when all of these hold, checked by
`Denominations::Service` and again by a database trigger:

1. the product is marketable (not a currency row);
2. its `metadata.family` is listed in `market.denomination_product_families`
   for that denomination;
3. its `metadata.payment_modes` declares the denomination code.

For `seeds` the only eligible family is `0x1_subscription`. Because only Special
subscriptions declare `seeds` in `payment_modes`, Exclusive subscriptions and all
non-game goods cannot be priced in seeds.

## Amounts and history

`amount_minor` is a positive integer count of the smallest unit (`10^-scale`).
`seeds` has scale `0`, so `amount_minor = 400` is presented as `400 ₴€£`.
Fractional input is rejected, never rounded.

The history is append-only, enforced by a trigger. The current price is the
latest row per `(sku, denomination)`. Writes use a revision lock, like USDT
pricing, so a stale or partially ineligible batch appends nothing.

Migration `022_issuer_denominations.sql` registers `seeds` and copies the
staged Special `metadata.seed_price` amounts into the history with source
`core`. It does not modify product metadata or earlier migrations.

## API

All routes use the public bearer token.

| Route | Purpose |
| --- | --- |
| `GET /v1/denominations` | active denominations |
| `GET /v1/denominations/:code/prices?locale=` | current prices of active, sellable, eligible products |
| `POST /v1/admin/denomination-prices` | append an administrator price batch: `actor_user_id`, `denomination`, `revision`, `prices: [{sku, amount_minor}]` |
| `GET /v1/admin/denomination-prices/history?actor_user_id=&limit=` | append-only history |

Inactive (staged) products are not returned by the public price route. While
the 0x1 subscriptions remain `inactive`, `GET /v1/denominations/seeds/prices`
is empty by design. Exposing a price is not checkout: seeds payment needs the
issuer's authoritative debit and is not implemented here.
