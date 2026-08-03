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
3. locks eligible listing rows;
4. normalizes broker supply prices to USDT where a currency rate exists;
5. chooses one listing by lowest normalized supply cost, then creation time and ID;
6. creates the provider quote;
7. moves the exact quantity from available to reserved inventory;
8. persists the listing ID, customer ID, quote ID, quantity, supply-price snapshot and expiration.

The MVP intentionally uses one listing per quote. The reservation contract can be extended later with multi-listing allocation without changing the buyer API.

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
