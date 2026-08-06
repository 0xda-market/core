# Broker supply routing

## Commercial contract

0xda-market is the seller of record at the catalog boundary. The administrator sets one `sale_price_usdt`; a broker submits a private supply ask in USDT or another supported currency. The buyer sees only the administrator price converted into the requested display currency.

```text
admin sale price
  -> profitability gate
  -> private broker ranking
  -> one reserved listing
  -> buyer quote at the unchanged admin price
```

A listing is executable only when the sale price covers its normalized ask, supply buffer, variable cost, fixed cost and required net margin. Non-executable listings remain visible to their owner but cannot receive an order.

## Traffic incentive

Each broker contributes at most one executable candidate per SKU: the broker's lowest normalized ask that can fulfill the quote quantity. This prevents a broker from capturing several traffic tiers by publishing the same supply in multiple currencies.

Broker candidates are ordered by normalized USDT ask. Creation time and listing ID are stable tie-breakers only. A quote ID provides an unpredictable, replay-stable routing seed:

- one eligible listing receives 100% of allocations;
- two eligible listings receive estimated shares of 80% and 20%;
- three or more receive 70% for `best`, 20% for `competitive`, and a shared 10% reserve pool for `unlikely` listings.

This is intentionally not a winner-takes-all auction. Lowering an ask moves a broker into a higher traffic tier and increases expected order flow, while reserve traffic keeps alternative supply warm. The selected listing must still have enough locked inventory for the complete quote quantity.

The routing result is deterministic for the same quote and candidate snapshot. A retry therefore cannot select a different broker merely because the request was repeated.

## Broker feedback and privacy

Broker listing responses may include private routing feedback:

- `execution_status` — `executable`, `superseded` or `not_executable`;
- `status` — `best`, `competitive`, `unlikely`, `superseded` or `not_executable`;
- `estimated_order_share` — the current tier estimate, not a guarantee;
- `eligible_supply_count` — number of executable offers for the SKU;
- `sale_price_usdt` — the administrator price;
- `maximum_ask` — the highest ask in the broker's own currency that satisfies the configured margin for one unit.

`superseded` means the same broker has a lower executable ask for that SKU; the higher listing receives no additional traffic share. The response never exposes broker identities, competitor asks or an exact competitor threshold. Buyer catalog, quote and order responses expose none of the routing fields.

## Extension boundary

Price is the only ranking signal in this stage because core does not yet own reliable failure, rejection or SLA statistics. Reliability and fulfillment speed may be added only after those events are persisted as auditable facts. They must refine ranking without changing the fixed buyer-price contract or weakening the profitability gate.
