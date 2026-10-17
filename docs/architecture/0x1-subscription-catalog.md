# 0x1 Special and Exclusive subscription catalog

0xda-market registers **eight separate digital subscription SKUs** for an
authenticated **0x1 Bond**, not for a Telegram account, device, Avaia, or
BondChain. They are not Telegram Premium resales.

| Duration | Special (USDT) | Special (Seeds ₴€£) | Exclusive (USDT) |
| --- | ---: | ---: | ---: |
| 1 month | 2.49 | 400 | 5.49 |
| 3 months | 6.29 | 1,020 | 13.99 |
| 6 months | 11.49 | 1,800 | 24.49 |
| 12 months | 14.99 | 2,400 | 32.99 |

Stable SKUs:
`0x1_special_1m`, `0x1_special_3m`, `0x1_special_6m`,
`0x1_special_12m`, `0x1_exclusive_1m`, `0x1_exclusive_3m`,
`0x1_exclusive_6m`, `0x1_exclusive_12m`.

## Money versus game currency

USDT is the market-owned sales price in the append-only
`market.product_prices` history. The introductory prices are inserted only
for previously unpriced SKUs; the migration never rewrites an administrator's
existing price history.

**₴€£ is the display glyph for Seeds, a single in-game currency identified
by `SEED`, not a request for UAH, EUR or GBP exchange rates.** Special
products carry the fixed integer `metadata.seed_price` with
`currency: "SEED"`, `symbol: "₴€£"` and the amount shown above.
No `market.products` currency row, FX provider, USDT/Seeds equivalence,
or client-side exchange conversion is created. Exclusive products have
**no Seeds purchase option**.

The market's existing currency-localized display of a *USDT quote* remains
independent of 0x1's Seeds denomination. The two payment paths must not be
combined into a single fiat conversion pipeline.

## Staged availability and ownership boundary

Migration `020_0x1_subscription_catalog.sql` registers these products
as **inactive, marketable catalog definitions**. Administrators can inspect
them, and their initial USDT price history is present, but they are
not visible in the active client catalog, do not receive broker inventory,
and cannot be quoted/purchased through the existing marketplace route.

This is deliberate: current marketplace fulfillment supports
broker-routed manual products and real-money payment settlement; it does not
grant authoritative 0x1 Bond subscription entitlements or debit 0x1 Seeds.
The metadata marker `purchase.fulfillment = "not_configured"` is
descriptive staging information, **not an implemented runtime checkout
guard**. The actual hard purchase gate while staging is `status=inactive`.

Before activating any SKU:
1. Resolve the authenticated Bond identity and recipient-bound contract,
   period overlaps, upgrades, refunds, expiration and revocation.
2. For USDT, require 0xda-market settlement confirmation, exactly-once
   fulfillment and an idempotent entitlement grant from the 0x1 authority.
3. For Seeds, require authoritative server-side balance checking, atomic
   debit and idempotent entitlement grant; do not trust browser balance
   or reuse the market's fiat settlement/FX pipeline.
4. Wire and test buyer presentation, quote, payment options, receipts,
   cancellations, and provider availability. The market must not promise
   a completed delivery while entitlement is unverified.
5. Only then deliberately enable product status and any required
   channel-specific route and supply configuration.

0x1 subscription benefits and their authority are specified in
[nilx-one/0x1: Special and Exclusive Subscriptions](https://github.com/nilx-one/0x1/blob/master/documents/product-direction/special-exclusive-subscriptions.md).
The updated prices in this document supersede that proposal's *provisional*
price examples, but do not independently activate its proposed benefits.
