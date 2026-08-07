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
append-only market price
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

Non-USDT asks are normalized through the existing persisted FX snapshot and freshness gate. Unsupported or stale FX makes only that listing invalid as an automatic-pricing input. Unexpected adapter/runtime failures are not swallowed as missing liquidity; they fail the refresh pass and remain operationally visible.

If no valid unit-executable supply exists, the system does not invent a new automatic price.

## Price stability rule

Automatic pricing is intentionally asymmetric.

1. If an active marketable product has no current client price and receives its first valid broker supply, the marketplace creates the minimum solvent price for the competitive reference band.
2. If the current client price becomes lower than that profitability floor because supply became more expensive, the marketplace raises the price.
3. If broker supply becomes cheaper, the marketplace does **not** automatically lower an already profitable client price.
4. An administrator may explicitly lower or override a client price; the profitability gate still prevents execution against insolvent supply, and the automatic worker may raise an override later if it falls below the current solvent floor.

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
raised
   ↓ otherwise
stable
```

A product without valid supply remains catalog-visible according to the existing catalog contract but cannot become executable merely because it exists.

## Runtime

`price-refresh` runs `bin/refresh_market_prices_loop` continuously. The default refresh interval is 60 seconds and is configurable through `MARKET_PRICE_REFRESH_INTERVAL_SECONDS`.

Relevant runtime policy:

- `MARKETPLACE_ROUTING_HEADROOM_BPS` — broker-routing room above the best normalized ask; default `500` (5%);
- `MARKETPLACE_MIN_MARGIN_BPS` — minimum marketplace net margin;
- `MARKETPLACE_SUPPLY_BUFFER_BPS` — supply-risk buffer;
- settlement variable/fixed costs — read through the same manual-v1 `CostResult` configuration used by execution;
- `FX_RATE_MAX_AGE_SECONDS` — hard freshness limit for non-USDT supply normalization.

The worker is idempotent. A pass with no required price changes appends no price rows.

The declarative `bin/market-bootstrap` introduced by PR #99 remains an operational reconciliation and explicit override tool. It is not the normal price-discovery mechanism.

## Invariants

- broker ask = broker earning for fulfilled allocated quantity;
- client price is owned by 0xda-market, never by a broker;
- the best valid broker ask anchors, but does not directly equal, the automatic pricing reference;
- routing headroom is bounded, server-controlled and never influenced by a more expensive competitor ask;
- unit automatic pricing ignores inventory that cannot fulfill one complete unit;
- automatic pricing and execution use the same `ProfitabilityPolicy`;
- settlement costs use the same manual-v1 `CostResult` configuration as execution;
- stale/unsupported FX fails closed for the affected non-USDT supply input;
- unexpected runtime failures fail the refresh pass instead of silently deleting liquidity;
- automatic repricing may raise an insolvent price but never lowers a profitable price;
- stale automatic price writes are rejected through the price-ledger revision contract;
- every automatic price remains append-only and uses source `core`.
