# Manual Settlement Runtime

Status: implemented in `agent/manual-settlement`
Scope: `0xda-market/core`

## Contract

The marketplace keeps its existing payment-aware order lifecycle, but payment assertion is no longer the financial source of truth for new orders. A durable settlement record owns the money-transfer state.

```text
quote
  -> settlement.cost(quote:) -> profitability gate
  -> accepted marketplace quote
  -> payment_pending order
  -> settlement.charge(order:) -> pending settlement
  -> trusted manual receipt
  -> settled settlement
  -> payment confirmation projection
  -> broker inventory committed
  -> fulfillment
```

`orders.payment` remains the stable order/API projection. `market.settlements` is the source of truth for expected and received USDT, provider state, tolerance, expiry, idempotency and external reference.

## Quote-time economics

`ManualSettlementProvider` owns the configured variable and fixed settlement costs. The composition root initializes the existing immutable `ProfitabilityPolicy` from that provider `CostResult`, and the settlement port is invoked again for every marketplace quote to validate the contract.

The administrator-owned buyer price remains fixed. Settlement cost changes supply eligibility and broker routing economics; it does not add a buyer-visible markup.

Runtime inputs:

- `MARKETPLACE_VARIABLE_FEE_BPS` — default cost of the manual settlement adapter;
- `MARKETPLACE_FIXED_COST_USDT` — default fixed cost of the manual settlement adapter;
- `MANUAL_SETTLEMENT_TOLERANCE_BPS` — accepted amount deviation for trusted manual receipt, default `0`.

These values configure the adapter. Pricing consumes the adapter's cost result rather than reading a separate fee source.

## Manual receipt

The existing trusted endpoint remains:

```text
POST /operator/v1/market/orders/:id/payment/confirm
```

Required input remains `reference`; provider data remains optional. `received_usdt` is additionally accepted. When omitted, the manual operator is asserting receipt of the exact expected amount.

The endpoint first settles the durable settlement record. Only a terminal `settled` record is allowed through the existing payment-confirmation, inventory-commit and fulfillment path. Amount mismatch and expiry fail closed before inventory is sold.

## Persistence invariants

- settlement idempotency keys are unique;
- at most one non-failed settlement exists per order;
- provider observations are append-only in `market.settlement_events`;
- optimistic concurrency uses `lock_version`;
- canonical settlement currency for v1 is USDT;
- legacy payment-aware orders without a settlement record retain their existing compatibility path.

## Deferred scope

Automated TON/USDT observation, custody, payouts, automated refunds, chargebacks, partial payments, multi-currency settlement and dynamic per-product/per-tenant provider selection remain outside this change.
