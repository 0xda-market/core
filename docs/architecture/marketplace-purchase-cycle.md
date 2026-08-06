# Marketplace Purchase Cycle

## Scope

This document defines the marketplace path from administrator product creation through broker liquidity, payment confirmation and provider-neutral fulfillment.

```text
inactive product
  -> reviewed active product + client price
  -> active broker listing
  -> listing allocation + reservation
  -> client quote
  -> payment-pending order
  -> trusted payment confirmation
  -> committed inventory
  -> provider-neutral fulfillment
```

The core models payment state and the confirmation boundary. Wallet balances, blockchain transfers, card acquiring, payout execution and automated settlement remain separate provider adapters.

## Product creation

`POST /v1/admin/products` creates one locale-neutral product and one initial localization in a single store transaction.

New products default to `inactive`. Creating a product does not make it purchasable. Activation and pricing remain explicit administrator operations.

The stable SKU cannot be edited through the product update surface. Duplicate SKU creation returns `duplicate_product`.

## Broker inventory

Each broker listing maintains four exact decimal balances:

```text
quantity = available_quantity + reserved_quantity + sold_quantity
```

- `quantity` is the broker's total committed inventory;
- `available_quantity` can be allocated to new quotes;
- `reserved_quantity` is held by unexpired quotes and unpaid orders;
- `sold_quantity` is committed only after trusted payment confirmation.

A broker cannot reduce total quantity below `reserved_quantity + sold_quantity`. Existing quote economics are not changed by later listing edits.

## Allocation and reservation

`POST /v1/market/quotes` accepts the internal customer UUID, product SKU and quantity.

The service:

1. verifies an active, marketable product and active client price;
2. releases expired reservations in the same store transaction;
3. fixes the provider quote at the administrator's current sale price;
4. locks active listings able to execute the full requested quantity;
5. normalizes broker asks to USDT and rejects asks that fail the profitability policy at that fixed sale price;
6. ranks profitable supply by ask and uses the quote ID to select the `best`, `competitive` or reserve traffic tier;
7. revalidates positive margin for the selected listing before mutation;
8. moves the exact quantity from available to reserved inventory;
9. persists the listing ID, customer ID, quote ID, quantity, supply-price snapshot and expiration.

The MVP intentionally uses one listing per quote. The reservation contract can be extended later with multi-listing allocation without changing the buyer API.

An expensive listing never changes the client price. If no current listing can execute profitably at the administrator price, quote creation returns `insufficient_liquidity` before inventory or an order is created. Once inventory is reserved, later listing or administrator price edits do not change the quote.

Routing shares and broker-facing feedback are defined in [Broker supply routing](broker-supply-routing.md).

## Profitability policy

Let:

- `C` be normalized broker supply cost for the complete requested quantity;
- `b` be the supply-risk buffer rate;
- `F` be fixed execution cost per order;
- `f` be variable fees as a share of client revenue;
- `m` be the required net margin as a share of client revenue.

The minimum client revenue is:

```text
R_min = (C * (1 + b) + F) / (1 - f - m)
```

This is a margin calculation, not a markup calculation. The policy rounds upward to six-decimal USDT precision and requires `m > 0` and `f + m < 100%` at startup.

Runtime parameters are provider-neutral:

- `MARKETPLACE_MIN_MARGIN_BPS` — minimum net margin; default `100` (1%);
- `MARKETPLACE_SUPPLY_BUFFER_BPS` — FX, spread and slippage reserve on supply cost; default `100` (1%);
- `MARKETPLACE_VARIABLE_FEE_BPS` — payment or settlement fees charged as a revenue percentage; default `0`;
- `MARKETPLACE_FIXED_COST_USDT` — fixed cost allocated once per quote; default `0`.

Catalog eligibility uses quantity `1`. Exact quote eligibility is quantity-aware, so a fixed order cost is amortized across the requested quantity. All four inputs are server-controlled and never accepted from browser or channel payloads.

## Quote acceptance

`POST /v1/market/quotes/:id/accept` creates a marketplace order in `payment_pending` state and attaches the reservation to that order.

Acceptance does not sell inventory:

```text
available: unchanged
reserved:  unchanged
sold:      unchanged
```

The order stores a payment document containing:

- `status: pending`;
- authoritative amount and currency;
- payment expiration inherited from the quote reservation;
- a stable idempotency key.

Repeating acceptance returns the same order and reservation. Provider execution is rejected with `payment_required` while payment remains pending.

## Trusted payment confirmation

The operator-authenticated endpoint is:

```text
POST /operator/v1/market/orders/:id/payment/confirm
```

It accepts a provider reference and provider-specific JSON data. The browser cannot call this endpoint and cannot assert that payment succeeded.

Confirmation performs three idempotent stages:

1. transition the order from `payment_pending` to `accepted` and persist the confirmation reference;
2. move the reservation from `payment_pending` to `committed`;
3. move inventory from reserved to sold and execute the provider-neutral fulfillment order.

```text
reserved:  - quantity
sold:      + quantity
```

If inventory commitment fails, core rolls the order back to `payment_pending`. A fulfillment failure does not roll payment or sold inventory back: the paid order remains recoverable through the provider retry and operator workflow.

Repeated payment confirmation does not consume inventory twice and reuses the same fulfillment idempotency key.

## Payment expiration and cancellation

An active or payment-pending reservation expires at the quote deadline. Expired inventory returns from reserved to available.

A payment confirmation after the deadline returns `payment_expired`. The corresponding unfulfilled order becomes cancelled once the expired reservation is reconciled.

Payment cancellation, refunds and post-payment disputes are not part of this stage. Those transitions require an explicit financial ledger and refund contract.

## Privacy

Buyer responses expose only client commercial terms, payment state and inventory state. They do not expose:

- broker identity;
- listing ID;
- broker supply price;
- broker supply currency.

The channel adapter must resolve the authenticated external identity to `market.users.id` and must not trust an actor ID supplied by browser code.

## Public marketplace API

- `POST /v1/market/quotes`
- `POST /v1/market/quotes/:id/accept`
- `GET /v1/market/orders/:id`
- `POST /v1/market/orders/:id/execute`

The execute endpoint is retained for idempotent retries after payment confirmation. It returns `payment_required` before confirmation.

## Trusted operator API

- `POST /operator/v1/market/orders/:id/payment/confirm`

The endpoint uses the existing manual-operator bearer token. A later payment-provider adapter may call the same marketplace service without changing inventory or fulfillment rules.

Generic intent, quote and order endpoints remain available. The marketplace endpoints compose those provider-neutral lifecycle primitives with catalog pricing, payment state and broker inventory.
