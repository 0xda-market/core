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

## Recipient: asked from the issuer

The recipient is always the customer's own issuer account. The market never
decides on its own whose account that is, and it keeps no copy of the issuer's
bindings. For each of the customer's channel accounts (for example a messenger
account, `provider` + `provider_user_id`) it asks the issuer's directory which
issuer account holds it. The issuer answers with that account's public handle
(`pub_dress`), or that the person must sign in with the issuer to connect it.

```text
customer --channel login--> market user + channel identity (e.g. messenger:123)
market   --lookup---------> issuer: messenger:123 -> pub_dress "zero" | sign in
order    --recipient------> "zero", snapshotted with link_provider / link_provider_user_id
```

- Only the issuer knows and enforces its binding rules. One channel account
  belongs to at most one issuer account, and one issuer account holds at most
  one channel account per provider. The market never writes a binding.
- The product's `metadata.purchase.recipient.provider` must equal the
  denomination's `issuer` and allow `self`.
- No binding: `409 issuer_account_unlinked`. Channel accounts that belong to
  different issuer accounts: `409 recipient_ambiguous`. The market never
  guesses whose balance to debit.
- An issuer that cannot answer (timeout, error status, malformed body) is
  `502 issuer_unavailable`, never "not linked". A person is never sent to link
  an account that may already be linked.
- The order snapshots `recipient_subject` (the `pub_dress`) and the channel
  account that selected it (`link_provider`, `link_provider_user_id`). The
  issuer can therefore check that the binding still holds before it debits.
- Customer responses never include the channel account id. A channel gets
  `linked`, and the public `pub_dress` when linked.

The directory is configured with `ISSUER_DIRECTORY_URL` (HTTPS) and
`ISSUER_DIRECTORY_TOKEN`, set together, and `ISSUER_DIRECTORY_PROVIDERS`, the
comma-separated channel providers the issuer binds. The market `POST`s
`{"provider","subject"}` with the bearer token and reads
`{"state":"linked","pub_dress"}` or `{"state":"sign_in_required","provider"}`.
Without them every lookup is `issuer_unavailable`.

### Channel flow

1. The channel calls `GET /v1/issuer-accounts/:issuer?actor_user_id=`.
2. If it returns `linked: true`, the channel shows the `pub_dress` and offers
   checkout in the denomination.
3. If it returns `linked: false`, the channel offers signing in with the issuer
   to connect this channel account. The issuer's own sign-in window enforces its
   binding rules. For example, if the issuer account already holds another
   account of that provider, that window says so.
4. After signing in, the channel re-checks the status. Nothing is published to
   the market: the next lookup sees the new binding.

## Ordering rules

A customer can order only goods that `GET /v1/denominations/:code/prices`
returns: active, sellable, eligible and priced. Staged (inactive) goods cannot be
ordered.

The client supplies an `idempotency_key` (8–128 of `A-Z a-z 0-9 . _ : -`).
Repeating a key returns the original order. Reusing it for a different good or
denomination is a `409 idempotency_conflict`.

## API

Customer routes on the public API (public bearer token, `actor_user_id` is the
customer). They are mounted only with `ENABLE_ISSUER_ORDER_ROUTES=1`, which is
off by default and refused in production until the customer-authentication
gate below is closed:

| Route | Purpose |
| --- | --- |
| `POST /v1/issuer-orders` | `actor_user_id`, `sku`, `denomination`, `idempotency_key`; `201` created, `200` replay |
| `GET /v1/issuer-orders/:id?actor_user_id=` | read own order; another customer's order is `404` |
| `POST /v1/issuer-orders/:id/cancel` | cancel own pending order |
| `GET /v1/issuer-accounts/:issuer?actor_user_id=` | `linked`, and the public `pub_dress` when linked |

Issuer routes are mounted at `/issuer` only when `ISSUER_API_TOKEN` and
`ISSUER_API_ISSUER` are both set. The token sees only the named issuer's orders.

| Route | Purpose |
| --- | --- |
| `GET /issuer/v1/orders?status=pending&limit=&cursor=` | oldest-first queue; `meta.next_cursor` fetches the next page |
| `GET /issuer/v1/orders/:id` | read one order |
| `POST /issuer/v1/orders/:id/claim` | take an order before debiting |
| `POST /issuer/v1/orders/:id/fulfil` | `issuer_reference`, `amount_minor`, `denomination`, `recipient_subject` |
| `POST /issuer/v1/orders/:id/reject` | `code` (`^[a-z][a-z0-9_]{1,63}$`) |

The expected issuer loop is: poll the queue, claim, perform the atomic debit
and grant keyed by the order `id`, then fulfil or reject.

## Recovery of processing orders

A `processing` order means the issuer claimed it; the market cannot tell
whether the debit and grant already happened. Recovery is driven by the issuer,
which owns that fact:

1. List claimed orders: `GET /issuer/v1/orders?status=processing`, following
   `meta.next_cursor` (`&cursor=`) until it is `null`. The queue is keyset
   paginated by `(created_at, id)`, so a long backlog of stuck orders never hides
   later ones.
2. For each one, look up the issuer's own operation keyed by the order `id`.
3. If the debit and grant completed, repeat `fulfil` with the same
   `issuer_reference` and the order's exact amount, denomination and recipient.
   The repeat is idempotent; a conflicting confirmation is refused, including
   on an already fulfilled order.
4. If nothing was debited, `reject` with a code. The issuer must never debit
   again under a new key for the same order.

The market never expires or cancels a `processing` order on its own, so a
completed debit is never orphaned by a market-side timeout. This procedure must
be rehearsed against a staging issuer before the issuer worker is enabled.

## Activation gates

Seeds checkout stays inactive until the gates below are met, each with an
integration test against the real channel and issuer.

### Customer authentication

Customer routes take `actor_user_id` from the request. The public API is
protected by the shared public bearer token, which identifies a trusted
channel, not a customer. The issuer directory narrows the risk: an order can
debit only the issuer account that the issuer itself binds to that customer's
channel account, and the issuer can re-check the snapshotted channel account before it
debits. What remains is trust in the channel: a holder of the public token who
claims to be `messenger:123` reaches the account bound to `messenger:123`.

This gate is enforced, not only documented: customer routes are off unless
`ENABLE_ISSUER_ORDER_ROUTES=1`, and a production boot with that flag refuses to
start. Lifting the production refusal is a separate change. It must come with a
verified customer boundary.

Before activation, the deployment must ensure that only the channel adapter,
which verifies the provider's own proof (for example signed host or login data), can reach customer routes with the public token. A cross-customer
attempt must be tested at that boundary.

### Issuer integration

The issuer must implement its side of the contract: answer directory
lookups for the market's token, run the claim → debit+grant →
fulfil/reject loop, and rehearse the recovery procedure above.
