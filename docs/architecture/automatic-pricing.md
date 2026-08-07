# Automatic Pricing

Status: implemented by PR #100
Scope: `0xda-market/core`

## Goal

Client prices are market-owned. Brokers never publish a buyer-facing price; they publish supply and the amount they want to receive for one fulfilled unit. The marketplace turns that broker ask into a solvent client price automatically.

The normal runtime path is:

```text
active marketable product
        +
available broker asks
        ↓
normalize asks to USDT through the FX freshness contract
        ↓
cheapest available supply cost
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

## Source of truth

Broker supply is the primary cost input. A broker listing means: **the broker expects to receive its ask if the allocated order is fulfilled**. Marketplace fees and settlement costs do not reduce that broker payable.

Settlement cost remains adapter-owned. Automatic pricing consumes the same `CostResult` contract described by `settlement-port.md`; it does not introduce a second fee formula.

FX remains platform-owned. Non-USDT asks are normalized through the existing persisted FX snapshot and freshness gate. If required FX data is unavailable or stale, that ask is not a valid automatic-pricing input.

## Price stability rule

Automatic pricing is intentionally asymmetric.

1. If an active marketable product has no current client price and receives its first valid broker supply, the marketplace creates the minimum solvent client price.
2. If the current client price becomes lower than the profitability floor because supply became more expensive, the marketplace raises the price.
3. If broker supply becomes cheaper, the marketplace does **not** automatically lower the client price. The difference becomes additional marketplace margin.
4. An administrator may explicitly lower or override a client price; the profitability gate still prevents execution against insolvent supply.

This prevents buyer prices from oscillating whenever brokers change asks while preserving the incentive for brokers to compete for routing share.

## Product lifecycle

Every `active` + `marketable` catalog product automatically participates. No fixed SKU allow-list is required.

```text
product created
   ↓
awaiting_supply
   ↓ first valid broker ask
priced
   ↓ supply cost exceeds current solvent floor
raised
   ↓ otherwise
stable
```

A product without supply remains catalog-visible according to the existing catalog contract but cannot become executable merely because it exists. The system never invents a price without an economic input.

## Runtime

`price-refresh` runs `bin/refresh_market_prices_loop` continuously. The default refresh interval is 60 seconds and is configurable through `MARKET_PRICE_REFRESH_INTERVAL_SECONDS`.

The worker is idempotent. A pass with no required price changes appends no price rows.

The declarative `bin/market-bootstrap` introduced by PR #99 remains an operational reconciliation and explicit override tool. It is not the normal price-discovery mechanism.

## Invariants

- broker ask = broker earning for fulfilled allocated quantity;
- client price is owned by 0xda-market, never by a broker;
- client price may not be automatically created without valid supply;
- automatic pricing and execution use the same `ProfitabilityPolicy`;
- settlement costs come through the settlement cost contract;
- stale FX fails closed for non-USDT supply;
- automatic repricing may raise an insolvent price but never lowers a profitable price;
- every automatic price remains append-only and uses source `core`.
