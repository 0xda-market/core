# Marketplace Purchase Cycle

## Scope

This document defines the implemented pre-wallet path from administrator product creation through broker liquidity and client order creation.

```text
inactive product
  -> reviewed active product + client price
  -> active broker listing
  -> listing allocation + reservation
  -> client quote
  -> accepted order
  -> provider-neutral fulfillment
```

Wallet balances, payout execution and automated settlement remain separate capabilities.

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
- `reserved_quantity` is held by unexpired client quotes;
- `sold_quantity` is committed to accepted orders.

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

## Quote and order privacy

Buyer responses expose only client commercial terms and inventory state. They do not expose:

- broker identity;
- listing ID;
- broker supply price;
- broker supply currency.

The channel adapter must resolve the authenticated external identity to `market.users.id` and must not trust an actor ID supplied by browser code.

## Acceptance

`POST /v1/market/quotes/:id/accept` accepts the provider quote idempotently and commits the corresponding reservation:

```text
available: unchanged
reserved:  - quantity
sold:      + quantity
```

The reservation stores the created order ID and becomes `committed`. Repeating the same acceptance returns the same order without consuming inventory again.

If inventory commitment fails after quote acceptance, core attempts to cancel the still-unexecuted order before returning the failure.

## Expiration and release

An active reservation becomes `released` after quote expiration or an explicit release command. Its quantity moves from reserved back to available inventory.

Expired reservations are released before availability checks and allocation, so abandoned checkouts do not permanently remove liquidity.

## API

- `POST /v1/admin/products`
- `POST /v1/market/quotes`
- `POST /v1/market/quotes/:id/accept`
- `GET /v1/market/orders/:id`
- `POST /v1/market/orders/:id/execute`

Generic intent, quote and order endpoints remain available. The marketplace endpoints compose those provider-neutral lifecycle primitives with catalog pricing and broker inventory.