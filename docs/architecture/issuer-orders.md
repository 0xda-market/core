# Issuer orders

An **issuer order** is a purchase of an eligible good paid in an
[issuer denomination](issuer-denominations.md), for example 0x1 Special
subscriptions paid in `seeds` (₴€£).

The issuer owns the balance, the debit and the entitlement grant, and performs
them as one atomic, idempotent operation on its side. The market records the
customer's request with a snapshotted price and recipient, then follows the
issuer's asynchronous decision. The two systems never call each other
synchronously.

## Seeds balance projection from 0x1

The `/nilx-browser/handoffs` endpoint accepts a display-only `seeds`
balance along with `seeds_authority`. A trusted 0x1 server can supply
`seeds_authority: "identity_snapshot"`: the number was read from the
issuer-owned Identity wallet, not asserted by a browser. Legacy handoffs
without the field remain `client_display`. Only the authenticated server
can post the handoff; arbitrary values are rejected.

Both are **historical snapshots for presentation**, not spend permission or
a payment proof. Before any purchase, the authenticated issuer order workflow
must independently claim the order, atomically debit the authoritative
Identity wallet and grant the entitlement. No balance copied into the Market
session may become a writable Market ledger or an issuer confirmation.

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

1. The trusted channel adapter validates signed provider login proof, resolves the market user, and calls `GET /v1/issuer-accounts/:issuer` with that verified customer context.
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

Customer routes require **both** the public bearer token (when configured) and
`zero_x_da.market.verified_customer_id` in the *server-side Rack environment*.
Only the trusted channel adapter may set this key after validating provider-signed
login proof and resolving the authenticated user's market identity. An HTTP header,
query string or JSON body field named `actor_user_id` never sets this context.
Missing context returns `401` before reaching the service. These routes are mounted
only with `ENABLE_ISSUER_ORDER_ROUTES=1`, which stays off by default and is refused
in production until the real channel adapter is integrated and tested:

| Route | Purpose |
| --- | --- |
| `POST /v1/issuer-orders` | `sku`, `denomination`, `idempotency_key`; `201` created, `200` replay |
| `GET /v1/issuer-orders/:id` | read own order; another customer's order is `404` |
| `POST /v1/issuer-orders/:id/cancel` | cancel own pending order |
| `GET /v1/issuer-accounts/:issuer` | `linked`, and the public `pub_dress` when linked |

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

Customer routes now require a server-side **verified customer context** in the Rack environment;
`actor_user_id` supplied by a client is ignored. The shared public API token
identifies the channel, **not** a human customer. The 0x1 partner directory resolves
which issuer account is linked to the authenticated customer's channel account,
but is not a substitute for customer authentication.

The adapter must validate the provider's signed login proof, reject stale/replayed
proof where applicable, resolve the verified provider identity to the market user,
and set `zero_x_da.market.verified_customer_id` on the internal Rack request. It
must not map an incoming `X-*` HTTP header to that trusted Rack key. If the adapter
cannot authenticate or resolve the user, it must fail closed. Core tests cover
missing context, forged headers, body/query impersonation and cross-customer
read/cancel/create attempts.

The gate is enforced: routes are disabled unless
`ENABLE_ISSUER_ORDER_ROUTES=1`, and production refuses that flag until a real
verified channel adapter and end-to-end proof test are in place. Do **not**
remove that refusal simply because the core's customer authorization tests pass.

### Issuer integration

The issuer must implement its side of the contract: answer directory
lookups for the market's token, run the claim → debit+grant →
fulfil/reject loop, and rehearse the recovery procedure above.
