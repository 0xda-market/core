# Issuer orders

An **issuer order** is a purchase of an eligible good paid in an
[issuer denomination](issuer-denominations.md), for example 0x1 Special
subscriptions paid in `seeds` (₴€£).

The issuer owns the balance, the debit and the entitlement grant, and performs
them as one atomic, idempotent operation on its side. The market records the
customer's request with a snapshotted price and recipient, then follows the
issuer's asynchronous decision. The two systems never call each other
synchronously.

## What this is not

Issuer orders are a separate path from the marketplace purchase cycle:

- no USDT price, FX conversion, profitability gate or market settlement;
- no broker inventory, reservation, routing or broker earning;
- no balance, hold or ledger of the denomination in the market;
- no browser-asserted payment or balance.

## Lifecycle

```text
pending ──claim──▶ processing ──fulfil──▶ fulfilled
   │                    │
   ├──cancel──▶ cancelled (customer, only before a claim)
   └──reject──▶ rejected ◀──reject──┘ (issuer, with a code)
```

- **pending:** the customer's request. The price (`amount_minor`, `price_id`)
  and recipient are frozen; later price changes do not affect it.
- **processing:** the issuer claimed the order. From this point the customer
  cannot cancel, so a cancellation never races a debit in progress.
- **fulfilled:** the issuer confirms it debited and granted. The confirmation
  must exactly match the order's amount, denomination and recipient, or it
  fails closed and the order is unchanged. An `issuer_reference` proves at most
  one order per issuer.
- **rejected:** the issuer declined, for example `insufficient_balance`.
- **cancelled:** the customer withdrew before any claim.

Every transition is idempotent for the same input, uses optimistic locking, and
appends an event to `market.issuer_order_events`, which is append-only.

## Recipient

The recipient is always the customer's own account at the issuer. The product's
`metadata.purchase.recipient.provider` must equal the denomination's `issuer`
and allow `self`. The customer must have an external identity with that
provider. Its `provider_user_id` is snapshotted as `recipient_subject`.

## Ordering rules

A customer can order only goods that `GET /v1/denominations/:code/prices`
returns: active, sellable, eligible and priced. Staged (inactive) goods cannot be
ordered.

The client supplies an `idempotency_key` (8–128 of `A-Z a-z 0-9 . _ : -`).
Repeating a key returns the original order. Reusing it for a different good or
denomination is a `409 idempotency_conflict`.

## API

Customer routes on the public API (public bearer token, `actor_user_id` is the
customer):

| Route | Purpose |
| --- | --- |
| `POST /v1/issuer-orders` | `actor_user_id`, `sku`, `denomination`, `idempotency_key`; `201` created, `200` replay |
| `GET /v1/issuer-orders/:id?actor_user_id=` | read own order; another customer's order is `404` |
| `POST /v1/issuer-orders/:id/cancel` | cancel own pending order |

Issuer routes are mounted at `/issuer` only when `ISSUER_API_TOKEN` and
`ISSUER_API_ISSUER` are both set. The token sees only the named issuer's orders.

| Route | Purpose |
| --- | --- |
| `GET /issuer/v1/orders?status=pending&limit=` | oldest-first queue |
| `GET /issuer/v1/orders/:id` | read one order |
| `POST /issuer/v1/orders/:id/claim` | take an order before debiting |
| `POST /issuer/v1/orders/:id/fulfil` | `issuer_reference`, `amount_minor`, `denomination`, `recipient_subject` |
| `POST /issuer/v1/orders/:id/reject` | `code` (`^[a-z][a-z0-9_]{1,63}$`) |

The expected issuer loop is: poll the queue, claim, perform the atomic debit
and grant keyed by the order `id`, then fulfil or reject. A crash between the
issuer's debit and the market's fulfil is recovered by repeating fulfil with the
same reference.

## Open contract

The identity service accepts provider keys matching `^[a-z][a-z0-9._-]{0,63}$`.
The seeds issuer and the 0x1 subscription recipient provider are both `0x1`,
which starts with a digit, so no customer can currently link a `0x1` identity.
Until the 0x1 identity integration chooses its provider key, seeds orders
cannot resolve a recipient, and they fail with `recipient_identity_unavailable`.
