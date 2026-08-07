# Automatic Pricing

Status: implemented by PR #100
Scope: `0xda-market/core`

## Goal

Client prices are market-owned. Brokers never publish a buyer-facing price; they publish supply and the amount they expect to receive for one fulfilled unit. Automatic pricing converts the best executable broker ask into a solvent buyer price while reserving a bounded amount of room for competitive broker routing.

The normal runtime path is:

```text
active marketable product
        +
unit-executable broker asks
        ↓
normalize asks to USDT through the FX freshness contract
        ↓
best valid supply cost
        ↓
CompetitiveReferencePolicy
  + market-owned routing headroom
        ↓
reference supply cost
        ↓
ProfitabilityPolicy
  + supply buffer
  + settlement CostResult
  + minimum marketplace margin
        ↓
minimum solvent client price
        ↓
AutomaticPriceIncreasePolicy
  + bounded uncorroborated increase
  + independent-supply corroboration for anomalous rises
        ↓
append-only market price or guarded no-op
```

The browser never performs this calculation.

## Broker safety and competitive reference

`broker ask = broker earning` remains the primary broker invariant. Marketplace fees, the supply buffer and settlement costs do not reduce the promised broker payable.

The cheapest valid broker ask anchors pricing, but automatic pricing does not price exactly at that ask's solvency boundary. `CompetitiveReferencePolicy` applies a server-owned routing headroom before `ProfitabilityPolicy` runs. The default is `500` basis points (5%) and is configured by `MARKETPLACE_ROUTING_HEADROOM_BPS`.

For a best normalized ask of `10 USDT`, the default reference supply cost is `10.5 USDT`. The client price is then derived so a broker ask up to that reference remains solvent under the same execution profitability policy.

This has four intended effects:

1. the best-priced broker still receives the best routing rank;
2. a broker that is only slightly more expensive is not made non-executable merely because the client price was set exactly against the cheapest ask;
3. another broker cannot raise the buyer price by posting an expensive ask, because headroom is derived only from the best ask and a fixed market policy;
4. the marketplace retains a hard profitability gate at reservation time, so broker safety never creates loss-making execution.

The headroom is not a broker fee and is not deducted from broker earnings. It is a client-pricing/routing policy owned by 0xda-market.

## Valid pricing supply

Automatic pricing uses the same unit quantity assumed by catalog eligibility. A listing must therefore have at least `1` unit of available inventory before it can anchor the unit client price.

The worker reads active available broker supply once per refresh and groups the snapshot by SKU in memory. This avoids one supply-store query per marketable product while retaining the same row-level eligibility contract.

Non-USDT asks are normalized through the existing persisted FX snapshot and freshness gate. The worker checks currency support/freshness before conversion; an unavailable rate excludes only that listing. A malformed amount or another `ArgumentError` from the conversion path is not treated as missing liquidity and fails the refresh pass visibly, as do other unexpected adapter/runtime failures.

If no valid unit-executable supply exists, the system does not invent a new automatic price.

## Price stability and increase guard

Automatic pricing is intentionally asymmetric.

1. If an active marketable product has no current client price and receives its first valid broker supply, the marketplace creates the minimum solvent price for the competitive reference band.
2. If an established price needs to rise by at most `1500` basis points (15%) to restore the current solvent floor, one valid broker is sufficient and the marketplace raises it automatically.
3. If the required increase is larger than 15%, the increase is anomalous and requires corroboration from at least two distinct brokers whose normalized asks are within `1000` basis points (10%) of the best ask. Otherwise the result is `guarded` and no price row is appended.
4. Corroborating asks never become a pricing anchor. They only confirm that the best ask reflects a broader supply regime; `CompetitiveReferencePolicy` still receives the cheapest valid ask.
5. If broker supply becomes cheaper, the marketplace does **not** automatically lower an already profitable client price.
6. An administrator may explicitly lower or override a client price; the profitability gate still prevents execution against insolvent supply, and the automatic worker may raise an override later if it falls below the current solvent floor and the increase policy allows that transition.

The default anomaly thresholds are market-owned runtime policy:

- `MARKETPLACE_AUTO_PRICE_MAX_UNCORROBORATED_INCREASE_BPS=1500`;
- `MARKETPLACE_AUTO_PRICE_CORROBORATION_SPREAD_BPS=1000`.

This is not a per-refresh rate limiter. A guarded outlier therefore cannot ratchet the price upward over repeated 60-second passes. The whole proposed transition is either accepted or rejected against the current persisted client price.

The no-automatic-decrease rule is broker-safe: a transient cheaper listing cannot immediately shrink the executable routing band for other brokers. It also prevents buyer prices from oscillating on every listing edit. Downward normalization remains an explicit market operation until a separate hysteresis contract is introduced.

## Concurrency contract

Automatic pricing participates in the same append-only, revisioned price ledger as administrator pricing.

Each pass captures the current pricing revision **before** reading the price snapshot. Any price write that happens after that point changes the ledger revision. When the worker later attempts to append its batch with the captured revision, the pricing store rejects the stale decision with `concurrency_conflict`.

This prevents an automatic decision computed from an older price snapshot from overwriting a newer administrator or core price.

## Product lifecycle

Every `active` + `marketable` catalog product automatically participates. No fixed SKU allow-list is required.

```text
product created
   ↓
awaiting_supply
   ↓ first valid unit-executable broker ask
priced
   ↓ reference floor exceeds current client price
   ├─ allowed transition ─────────────→ raised
   └─ anomalous + uncorroborated ─────→ guarded
   ↓ otherwise
stable
```

`guarded` preserves the current client price and appends no ledger row. The worker result includes the proposed `required_price_usdt` and `guard_reason=uncorroborated_increase` so operations can distinguish a safety intervention from ordinary stability.

A product without valid supply remains catalog-visible according to the existing catalog contract but cannot become executable merely because it exists.

## Runtime

`price-refresh` runs `bin/refresh_market_prices_loop` continuously. The default refresh interval is 60 seconds and is configurable through `MARKET_PRICE_REFRESH_INTERVAL_SECONDS`.

Relevant runtime policy:

- `MARKETPLACE_ROUTING_HEADROOM_BPS` — broker-routing room above the best normalized ask; default `500` (5%);
- `MARKETPLACE_AUTO_PRICE_MAX_UNCORROBORATED_INCREASE_BPS` — largest established-price increase one broker may justify; default `1500` (15%);
- `MARKETPLACE_AUTO_PRICE_CORROBORATION_SPREAD_BPS` — maximum spread from the best ask for independent supply to corroborate an anomalous rise; default `1000` (10%);
- `MARKETPLACE_MIN_MARGIN_BPS` — minimum marketplace net margin;
- `MARKETPLACE_SUPPLY_BUFFER_BPS` — supply-risk buffer;
- settlement variable/fixed costs — read through the same manual-v1 `CostResult` configuration used by execution;
- `FX_RATE_MAX_AGE_SECONDS` — hard freshness limit for non-USDT supply normalization.

The worker is idempotent. A pass with no required price changes, including a guarded pass, appends no price rows.

The declarative `bin/market-bootstrap` introduced by PR #99 remains an operational reconciliation and explicit override tool. It is not the normal price-discovery mechanism.

## Invariants

- broker ask = broker earning for fulfilled allocated quantity;
- client price is owned by 0xda-market, never by a broker;
- the best valid broker ask anchors, but does not directly equal, the automatic pricing reference;
- routing headroom is bounded, server-controlled and never influenced by a more expensive competitor ask;
- corroborating asks can authorize an anomalous transition but never replace the cheapest ask as the pricing anchor;
- a single transient or mistyped ask cannot ratchet an established client price through an anomalous increase;
- unit automatic pricing ignores inventory that cannot fulfill one complete unit;
- automatic pricing and execution use the same `ProfitabilityPolicy`;
- settlement costs use the same manual-v1 `CostResult` configuration as execution;
- unavailable FX fails closed only for the affected non-USDT supply input;
- malformed pricing values and unexpected runtime failures fail the refresh pass instead of silently deleting liquidity;
- automatic repricing may raise an insolvent price but never lowers a profitable price;
- stale automatic price writes are rejected through the price-ledger revision contract;
- every automatic price remains append-only and uses source `core`.
