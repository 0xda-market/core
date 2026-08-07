# Settlement Port

Status: draft
Scope: `0xda-market/core`
Change type: architecture proposal, no implementation

## Problem

The core can quote, accept, execute and fulfil an order. It cannot take money.

Two consequences are visible in the current contract:

- `MARKETPLACE_VARIABLE_FEE_BPS` and `MARKETPLACE_FIXED_COST_USDT` default to zero
  "until a settlement adapter supplies a cost contract". The margin gate therefore
  computes a gross margin and calls it net.
- The `accepted -> processing` transition assumes the client has paid, without any
  record that a payment occurred, when it occurred, or how much of it arrived.

Settlement is the only missing element of the value chain. Every other capability
in the core already exists.

## Position in the lifecycle

Settlement occupies the existing gap between `accepted` and `processing`. No new
top-level order state is introduced for the synchronous case:

```
intent -> quote -> accepted -> [settlement] -> processing -> succeeded
                                    |
                                    +-> settlement pending
                                    +-> settlement failed -> cancelled
```

Asynchronous settlement (on-chain confirmations, operator confirmation) mirrors the
existing deferred-fulfilment mechanism. The core already distinguishes
`ExecutionResult` from `PendingResult`; settlement reuses that shape rather than
introducing a second vocabulary for the same idea.

## Port contract

Symmetric to the fulfilment provider port:

```
settlement.key
settlement.cost(quote:)                          -> Contracts::CostResult
settlement.charge(order:, idempotency_key:)      -> SettlementResult | PendingSettlement
settlement.verify(settlement:)                   -> SettlementResult | PendingSettlement
```

`Core::Kernel` gains one port dependency. It does not gain the words TON, USDT,
Fragment, card or bank.

### `cost` is called at quote time, not at execution time

This is the decision that closes the open hole in the margin gate. The adapter that
takes the money is the only component that knows what taking the money costs, so it
declares that cost as part of quoting:

```
CostResult:
  variable_fee_bps  Integer
  fixed_cost_usdt   BigDecimal
```

The supply gate then enforces `strictly_positive_margin` against a net figure. The
environment variables become defaults for a null adapter, not the source of truth.

### Amount tolerance

Exact-amount matching is unworkable for on-chain transfers. The settlement record
carries an expected amount and a tolerance band in basis points. Anything outside
the band fails closed and becomes an operator task rather than a silent accept.
The tolerance is adapter-declared, not global.

## Persistence

```
market.settlements
  id                uuid pk
  order_id          uuid not null references market.orders(id)
  provider_key      text not null
  state             text not null   -- pending | settled | failed | expired
  expected_usdt     numeric not null
  received_usdt     numeric
  currency          text not null
  tolerance_bps     integer not null
  idempotency_key   text not null unique
  external_reference text
  provider_data     jsonb not null default '{}'
  expires_at        timestamptz
  lock_version      integer not null default 0
  created_at        timestamptz not null
  updated_at        timestamptz not null

  unique (order_id) where state <> 'failed'
```

`market.settlement_events` is append-only and records every observed provider
transition with provenance, matching the treatment of `market.product_prices`.

`provider_data` stays opaque to the core, consistent with the existing boundary
contract.

## Invariants

1. An order never transitions to `processing` without a terminal `settled`
   settlement. Fail closed.
2. One effective settlement per order. Retries reuse the idempotency key.
3. Settlement expiry reuses quote-expiry semantics rather than inventing a second
   clock.
4. Amounts are held in the USDT contract. Presentation currency conversion reuses
   the existing FX pipeline and its freshness gate.
5. If fulfilment fails after settlement succeeded, the order records
   `refund_required` and produces an operator task. Automated refunds are out of
   scope for v1; the obligation must still be durable and visible.

## Rollout

Ship `ManualSettlementProvider` first.

It mirrors the existing `ManualProvider`: the client is shown payment details, an
operator confirms receipt through the operator API, and the order proceeds. It has
no external dependency, no key management, no chain reorg handling, and it is fully
testable. It unblocks the entire money path in one small correct change and proves
the port shape against a real order before any network adapter exists.

Sequence:

1. in-memory adapter + contracts + architecture tests;
2. `ManualSettlementProvider` and PostgreSQL persistence;
3. margin gate consumes `CostResult`;
4. first automated adapter (TON/USDT), behind the same port.

## Non-goals

Automated refunds, chargeback handling, partial payments, multi-currency settlement
in a single order, custody of client balances.

## Open questions

- Does an unpaid accepted order cancel on expiry, or remain claimable? Current
  quote expiry suggests cancel; broker reservation semantics may argue otherwise.
- Is the settlement provider selectable per product, per tenant, or per order?
- Should `cost` failures degrade to the environment-variable defaults, or fail the
  quote? Failing closed is consistent with the FX freshness gate.
