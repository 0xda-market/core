# Settlement Port

Status: implemented (manual v1)
Scope: `0xda-market/core`
Change type: normative architecture contract

## Purpose

Settlement is the provider-agnostic boundary between an accepted order and money that the marketplace can trust. The first implementation is `ManualSettlementProvider`; future network adapters must preserve the same contract.

The settlement cost contract is also an input to marketplace pricing. Quote-time profitability and automatic client pricing must consume the same adapter-declared cost rather than maintain independent fee formulas.

## Position in the lifecycle

Settlement occupies the boundary between accepted purchase intent and fulfilment:

```text
intent -> quote -> accepted -> [settlement] -> processing -> succeeded
                                    |
                                    +-> settlement pending
                                    +-> settlement failed -> cancelled
```

Asynchronous settlement mirrors the existing deferred-fulfilment mechanism. The core does not gain provider-specific vocabulary for TON, USDT, cards, banks, or future rails.

## Port contract

```text
settlement.key
settlement.cost(quote:)                          -> Contracts::CostResult
settlement.charge(order:, idempotency_key:)      -> SettlementResult | PendingSettlement
settlement.verify(settlement:)                   -> SettlementResult | PendingSettlement
```

### Cost is known before economic commitment

The adapter that takes money is the component that knows what taking money costs. It therefore declares:

```text
CostResult
  variable_fee_bps  Integer
  fixed_cost_usdt   BigDecimal
```

`ProfitabilityPolicy` consumes this cost before a quote can reserve supply. The automatic-pricing worker described in `automatic-pricing.md` consumes the same manual-v1 cost configuration when deriving the minimum solvent client price.

The current manual provider exposes a static `default_cost`, configured from the same server-controlled variable and fixed-cost values used by the API composition root. Automatic pricing does not introduce a competing fee formula. A future provider with dynamic per-quote costs must expose a deterministic pricing-safe reference cost contract before it can replace the static manual-v1 composition.

Environment configuration may configure a concrete adapter, but it is not a second pricing source of truth.

### Amount tolerance

The settlement record carries an expected amount and an adapter-declared tolerance band. Anything outside that band fails closed rather than becoming a silent successful payment.

## Persistence

`market.settlements` is the durable source of truth for money movement. It records provider, state, expected and received amounts, currency, tolerance, idempotency key, provider reference/data, expiry and optimistic-lock version.

`market.settlement_events` is append-only and records observed provider transitions with provenance. `provider_data` remains opaque to core.

## Invariants

1. A settlement-required order never begins fulfilment without terminal `settled` state.
2. One effective settlement exists per order; retries reuse the idempotency contract.
3. Settlement amount and tolerance are provider-owned facts.
4. Presentation currency conversion reuses the platform FX pipeline and freshness gate.
5. Quote-time profitability and automatic pricing use the same settlement cost values; manual v1 exposes them as a static `CostResult`.
6. Settlement failure after an economic commitment fails closed and remains durable/operator-visible.

## Implemented v1

`ManualSettlementProvider` provides the first concrete adapter. It supports durable pending settlement, operator confirmation, expiry, amount tolerance and idempotency without introducing chain-specific behavior.

Implemented sequence:

1. settlement contracts and in-memory adapter;
2. PostgreSQL settlement persistence;
3. `ManualSettlementProvider`;
4. net-margin gate consuming `CostResult`;
5. automatic pricing consuming the same manual-v1 settlement cost configuration.

The next adapter may automate a real payment rail, but it must not change marketplace pricing or order lifecycle contracts. If its cost is dynamic, the adapter must first define a deterministic pre-commit pricing reference compatible with the existing profitability gate.

## Non-goals

Automated refunds, chargeback handling, partial payments, multi-currency settlement in a single order, and custody of client balances remain outside this contract until explicitly designed.
