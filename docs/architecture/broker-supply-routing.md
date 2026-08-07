# Broker supply routing

## Commercial contract

0xda-market is the seller of record at the catalog boundary. The buyer sees one market-owned client price converted into the requested display currency. A broker submits a private supply ask in USDT or another supported currency and, if allocated and fulfilled, earns that ask.

```text
market-owned client price
  -> profitability gate
  -> private broker ranking
  -> one reserved listing
  -> buyer quote at the unchanged current price
```

The current client price can come from an explicit administrator application or from automatic pricing. Broker asks never become buyer-facing prices directly.

A listing is executable only when the current client price covers its normalized ask, supply buffer, settlement cost and required net margin. Non-executable listings remain visible to their owner but cannot receive an order.

## Automatic pricing and broker safety

Automatic pricing uses the best valid unit-executable normalized broker ask as an anchor, then applies a bounded market-owned routing headroom before deriving the client price. The default headroom is 500 basis points (5%).

This distinction matters:

- the cheapest broker remains the `best` routing candidate;
- brokers slightly above the best ask can remain executable and compete for `competitive`/reserve traffic;
- an expensive competitor cannot push the client price upward because competitor asks are not inputs to the headroom calculation;
- lowering an ask improves ranking and can increase marketplace margin without reducing the broker's promised payout;
- a transient cheaper listing does not automatically lower the current client price and unexpectedly de-execute other brokers.

The broker contract remains exact: **broker ask = broker earning** for fulfilled allocated quantity. Routing headroom is a market pricing policy, not a deduction from broker proceeds.

## Traffic incentive

Each broker contributes at most one executable candidate per SKU: the broker's lowest normalized ask that can fulfill the quote quantity. This prevents a broker from capturing several traffic tiers by publishing the same supply in multiple currencies.

Broker candidates are ordered by normalized USDT ask. Creation time and listing ID are stable tie-breakers only. A quote ID provides an unpredictable, replay-stable routing seed:

- one eligible listing receives 100% of allocations;
- two eligible listings receive estimated shares of 80% and 20%;
- three or more receive 70% for `best`, 20% for `competitive`, and a shared 10% reserve pool for `unlikely` listings.

This is intentionally not a winner-takes-all auction. Lowering an ask moves a broker into a higher traffic tier and increases expected order flow, while reserve traffic keeps alternative executable supply warm. The selected listing must still have enough locked inventory for the complete quote quantity.

Automatic pricing is designed not to collapse this routing model by setting the buyer price exactly at the cheapest broker's solvency boundary. The bounded reference band creates room for competition while retaining a hard upper economic limit.

The routing result is deterministic for the same quote and candidate snapshot. A retry therefore cannot select a different broker merely because the request was repeated.

## Broker feedback and privacy

Broker listing responses may include private routing feedback:

- `execution_status` — `executable`, `superseded` or `not_executable`;
- `status` — `best`, `competitive`, `unlikely`, `superseded` or `not_executable`;
- `estimated_order_share` — the current tier estimate, not a guarantee;
- `eligible_supply_count` — number of executable offers for the SKU;
- `sale_price_usdt` — the current market-owned client price;
- `maximum_ask` — the highest ask in the broker's own currency that satisfies the configured profitability policy for one unit.

`maximum_ask` is derived from the current client price, so an automatically priced product naturally exposes the current executable ceiling created by routing headroom plus profitability constraints.

`superseded` means the same broker has a lower executable ask for that SKU; the higher listing receives no additional traffic share. The response never exposes broker identities, competitor asks or an exact competitor threshold. Buyer catalog, quote and order responses expose none of the routing fields.

## Extension boundary

Price is the only ranking signal in this stage because core does not yet own reliable failure, rejection or SLA statistics. Reliability and fulfillment speed may be added only after those events are persisted as auditable facts. They must refine ranking without weakening the profitability gate, changing the broker earning invariant or exposing competitor-sensitive information.
