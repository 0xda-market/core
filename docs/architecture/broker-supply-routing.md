# Broker supply routing

## Commercial contract

0xda-market is the seller of record at the catalog boundary. The buyer sees one market-owned client price converted into the requested display currency. A broker submits a private supply ask in USDT or another supported currency and, if allocated and fulfilled, earns that ask.

```text
market-owned client price
  -> profitability gate
  -> private broker allocation
  -> one reserved listing
  -> buyer quote at the unchanged current price
```

The current client price can come from an explicit administrator application or from automatic pricing. Broker asks never become buyer-facing prices directly.

A listing is executable only when the current client price covers its normalized ask, supply buffer, settlement cost and required net margin. Non-executable listings remain visible to their owner but cannot receive an order.

## Automatic pricing and broker safety

Automatic pricing uses the best valid unit-executable normalized broker ask as an anchor, then applies a bounded market-owned routing headroom before deriving the client price. The default headroom is 500 basis points (5%).

This distinction matters:

- the cheapest broker remains the strongest routing candidate;
- brokers slightly above the best ask can remain executable and compete for traffic;
- an expensive competitor cannot push the client price upward because competitor asks are not inputs to the headroom calculation;
- lowering an ask inside the competitive spread improves expected order share without requiring a rank crossover; crossing into the competitive spread restores access to price-performance traffic;
- the broker receives exactly the submitted ask on future fulfilled allocations, while an unchanged buyer price may leave additional marketplace margin;
- a transient cheaper listing does not automatically lower the current client price and unexpectedly de-execute other brokers.

The broker contract remains exact: **broker ask = broker earning** for fulfilled allocated quantity. Routing headroom is a market pricing policy, not a deduction from broker proceeds.

## Price-sensitive traffic incentive

Each broker contributes at most one executable candidate per SKU: the broker's lowest normalized ask that can fulfill the quote quantity. This prevents a broker from multiplying traffic share by publishing the same supply in multiple currencies.

Broker candidates are ordered by normalized USDT ask. Creation time and listing ID are stable tie-breakers only. A quote ID provides an unpredictable, replay-stable routing seed.

The default allocation has two components:

1. **reserve pool:** 10% of traffic is split evenly across all executable brokers so alternative supply remains warm;
2. **price-performance pool:** the remaining 90% is distributed according to each broker's price score relative to the best ask.

For an executable broker ask `A`, best executable ask `B`, and default competitive spread `S = 1000` basis points (10%):

```text
gap_bps = floor((A / B - 1) * 10_000)
remaining_bps = max(S - gap_bps, 0)
price_score = remaining_bps^2
```

The 90% performance pool is divided proportionally by `price_score`. The quadratic curve makes a meaningful price disadvantage reduce expected traffic without introducing a hard winner-takes-all cutoff. At or beyond the 10% competitive spread the price score is zero, but the broker still retains its share of the reserve pool while the listing remains profitable and executable.

The default two-broker examples are:

| Relative ask | Best broker | Other broker |
| --- | ---: | ---: |
| equal asks | 50.00% | 50.00% |
| +1% | 54.72% | 45.28% |
| +2% | 59.88% | 40.12% |
| +5% | 77.00% | 23.00% |
| +10% or more | 95.00% | 5.00% |

The percentages are allocation estimates in basis-point precision, not guarantees over a small number of orders. They describe the deterministic hash space used by routing, so larger order samples converge toward the published share.

With only one executable broker, that broker receives 100% of allocations. This is the intended first-production behavior: no special founder or administrator routing exception is required.

## Selection and replay stability

The policy converts the calculated shares into exactly 10,000 allocation basis points. Integer remainders are distributed deterministically by price rank so the allocation always sums to 100%.

The quote ID is hashed into the same 10,000-basis-point space. The selected candidate is the one whose cumulative allocation contains that bucket. The same quote ID and candidate snapshot therefore select the same broker on retry.

The selected listing must still have enough locked inventory for the complete quote quantity, and the reservation-time profitability policy remains authoritative. Price-sensitive routing never makes an unprofitable listing executable.

## Broker feedback and privacy

Broker listing responses may include private routing feedback:

- `execution_status` — `executable`, `superseded` or `not_executable`;
- `status` — `best`, `competitive`, `unlikely`, `superseded` or `not_executable`;
- `estimated_order_share` — the current price-sensitive allocation estimate, not a guarantee;
- `eligible_supply_count` — number of executable broker candidates for the SKU;
- `sale_price_usdt` — the current market-owned client price;
- `maximum_ask` — the highest ask in the broker's own currency that satisfies the configured profitability policy for one unit.

`best` applies to every executable broker tied at the lowest normalized ask. An executable broker above the best ask is `competitive` while its relative gap remains inside the configured competitive spread; at or beyond that spread it is `unlikely` and receives reserve-only traffic.

`maximum_ask` is derived from the current client price, so an automatically priced product naturally exposes the current executable ceiling created by routing headroom plus profitability constraints.

`superseded` means the same broker has a lower executable ask for that SKU; the higher listing receives no additional traffic share. The response never exposes broker identities, competitor asks or an exact competitor threshold. Buyer catalog, quote and order responses expose none of the routing fields.

## Invariants

- broker ask = broker earning for fulfilled allocated quantity;
- buyer-facing price remains market-owned;
- profitability is checked before routing and again before reservation mutation;
- one broker contributes at most one candidate per SKU;
- equal asks receive equal economic weight;
- lowering an executable ask cannot reduce that broker's allocation share while the competing snapshot is unchanged;
- inside the competitive spread, each basis-point improvement can increase the broker's price-performance allocation;
- the default 10% reserve pool is split evenly across all executable brokers, creating a bounded nonzero exploration floor for alternatives;
- allocation always sums to exactly 10,000 basis points;
- retries are stable for the same quote and candidate snapshot;
- competitor identity and exact competitor asks remain private.

## Extension boundary

Price is the only allocation-quality signal in this stage because core does not yet own reliable failure, rejection or SLA statistics. Reliability and fulfillment speed may be added only after those events are persisted as auditable facts. They must refine allocation without weakening the profitability gate, changing the broker earning invariant or exposing competitor-sensitive information.
