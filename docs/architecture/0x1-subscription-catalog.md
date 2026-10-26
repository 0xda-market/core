# 0x1 Special and Exclusive subscription catalog

0xda-market registers **eight separate digital subscription SKUs** for an
authenticated **0x1 Bond**, not for a third-party messaging account, device, Avaia, or
BondChain. They are not third-party subscription resales.

| Duration | Special (USDT) | Special (seeds ₴€£) | Exclusive (USDT) |
| --- | ---: | ---: | ---: |
| 1 month | 2.49 | 640 | 4.99 |
| 3 months | 6.29 | 1,632 | 12.69 |
| 6 months | 9.69 | 2,496 | 19.49 |
| 12 months | 14.99 | 3,840 | 29.99 |

### Subscription term promotional price

The approved monthly bases are **Special 2.49 USDT**, **Exclusive 4.98 USDT**
(2 × Special), and **Special 640 seeds**. The nominal duration discounts are
0% (1 month), 15% (3), 35% (6), and 50% (12), identical for both tiers.
Calculate each USDT raw term amount using exact decimal arithmetic, then
choose the nearest positive allowed cent ending **.29, .49, .69 or .99**;
ties favor the lower buyer price. The system does not round each month's
price separately, and it does not reapply the discount after promotion.

The generic `Pricing::TermPromotionPolicy` accepts the monthly base,
duration, discount basis points and allowed endings as **inputs**, not
provider-specific defaults. These numbers are this catalog's data.
For example, Special 3m: 2.49 × 3 × 0.85 = 6.3495 → **6.29 USDT**;
Special 12m: 2.49 × 12 × 0.5 = 14.94 → **14.99 USDT**.
Consequently the displayed *nominal* 50% discount may be slightly different
from the effective discount. If offering a legally precise percentage,
display the effective ratio instead. The Exclusive promotional output may
differ from exactly twice the final Special price; its **undiscounted monthly
anchor** is exactly 2× Special.

**This is not client FX rounding.** Unlike the upward-only currency
presentation rule, the promotion may adjust a USDT term price either up
or down before it is appended to `market.product_prices`. The price
history is append-only: migration 025 adds only changed introductory
prices to untouched system-owned **inactive** SKUs, never rewriting a
user/admin-set quote or an existing price record. The target seeds prices
are separate exact integers and use no promotion/FX. Exclusive remains
**USDT-only** with no seeds denomination price.

Stable SKUs:
`0x1_special_1m`, `0x1_special_3m`, `0x1_special_6m`,
`0x1_special_12m`, `0x1_exclusive_1m`, `0x1_exclusive_3m`,
`0x1_exclusive_6m`, `0x1_exclusive_12m`.

## Money versus game currency

USDT is the market-owned sales price in the append-only
`market.product_prices` history. The introductory prices are inserted only
for previously unpriced SKUs; the migration never rewrites an administrator's
existing price history.

**₴€£ is the display glyph for seeds, a single in-game currency identified
by `seeds`, not a request for UAH, EUR or GBP exchange rates.** Special
products carry the fixed integer `metadata.seed_price` with
`currency: "seeds"`, `symbol: "₴€£"` and the amount shown above.
No `market.products` currency row, FX provider, USDT/seeds equivalence,
or client-side exchange conversion is created. Exclusive products have
**no seeds purchase option**.

Currency identifiers and visible English names are **lowercase**: `seeds`
(plural, currency identifier), `seed` (singular). The glyph `₴€£` has no
letter case and is displayed as-is. Migration
`021_normalize_0x1_seeds_identifier.sql` upgrades legacy `SEED` catalog
metadata without modifying migration 020 or its checksum.

Localized quantity labels use number-dependent forms for **whole units**:

| Locale | 1 | 2–4 | 5+ |
| --- | --- | --- | --- |
| `en_US` | seed | seeds | seeds |
| `uk_UA` | сід | сіди | сідів |
| `ru_RU` | сид | сида | сидов |

For `uk_UA` and `ru_RU`, integers ending in 11–14 take the 5+
form; otherwise the last digit 1 uses the singular, 2–4 the few form,
and all remaining endings use the many form. Examples: `1 сід`,
`3 сіди`, `5 сідів`, `11 сідів`, `21 сід`, `22 сіди`;
`1 сид`, `3 сида`, `5 сидов`, `11 сидов`, `21 сид`.
For compact prices use the uninflected glyph: `400 ₴€£`. These display
rules describe the future UI integration; current core only persists the
denomination and does not implement a quantity formatter.

The market's existing currency-localized display of a *USDT quote* remains
independent of 0x1's seeds denomination. The two payment paths must not be
combined into a single fiat conversion pipeline.

## Staged availability and ownership boundary

Migration `020_0x1_subscription_catalog.sql` registers these products
as **inactive, marketable catalog definitions**. Administrators can inspect
them, and their initial USDT price history is present, but they are
not visible in the active client catalog, do not receive broker inventory,
and cannot be quoted/purchased through the existing marketplace route.

This is deliberate: current marketplace fulfillment supports
broker-routed manual products and real-money payment settlement; it does not
grant authoritative 0x1 Bond subscription entitlements or debit 0x1 seeds.
The metadata marker `purchase.fulfillment = "not_configured"` is
descriptive staging information, **not an implemented runtime checkout
guard**. The actual hard purchase gate while staging is `status=inactive`.

A channel adapter may opt into `GET /v1/products?preview_0x1=true`.
Only staged inactive 0x1 products are added to the authenticated catalog response,
with `preview: true`, `available: false` and `price: null`. The optional
`attributes.preview_price` is a **non-executable, read-only catalog estimate**
from the current market-owned USDT price history; it uses current currency
presentation when available, otherwise USDT. When no price is recorded it is
`null`. Neither the original `price` field nor quote/order APIs change.
The ordinary
`/v1/products` and checkout routes remain unchanged. Other inactive products
are never exposed. The channel adapter must use a non-purchasing callback for
preview-only rows.

Before activating any SKU:
1. Resolve the authenticated Bond identity and recipient-bound contract,
   period overlaps, upgrades, refunds, expiration and revocation.
2. For USDT, require 0xda-market settlement confirmation, exactly-once
   fulfillment and an idempotent entitlement grant from the 0x1 authority.
3. For seeds, require authoritative server-side balance checking, atomic
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
