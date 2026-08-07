# Broker payouts

## Contract

0xda-market treats the broker's listing ask as the broker's promised earnings. Marketplace margin, buyer pricing, FX presentation, settlement fees, and platform execution costs do not reduce that promised amount after allocation.

The broker workflow is intentionally small:

1. provide liquidity and choose an ask;
2. fulfill allocated paid orders;
3. configure one payout destination and optional minimum payout threshold;
4. receive payouts.

Everything else is platform-owned automation.

## Earnings states

`pending` is created when an order is allocated to a broker. `available` is reached only after paid fulfillment succeeds. `payout_queued` means the earning has been atomically assigned to one payout batch. `paid` means an operator or future payout adapter has confirmed an external transfer reference. `void` is reserved for explicit reversal flows.

An earning cannot belong to more than one payout batch.

## Self-service profile

A broker can configure:

- payout currency: currently canonical `USDT`;
- network;
- destination;
- minimum payout amount;
- enabled/disabled state.

Changing the profile never mutates already queued payouts. Each payout snapshots the network and destination used when it was created.

## Automatic batching

When a payout is requested, all currently `available` earnings for the broker are batched atomically. If the total is below the broker's configured minimum, no state changes occur.

The idempotency key is derived from the broker and the exact earning set unless the caller supplies one explicitly. Repeating the same request therefore cannot duplicate a payout for the same earning set.

## Manual-approved executor

The first executor is intentionally simple: the platform creates a queued payout, an operator performs the USDT transfer, and the operator confirms the payout with the external transaction/reference. Confirmation atomically moves the payout and all attached earnings to `paid`.

This keeps custody out of the core while preserving the final provider contract. A future automated wallet or custody adapter can replace only the execution step without changing broker-facing economics or ledger state.

## API surface

Broker self-service:

- `GET /v1/broker/earnings`
- `GET /v1/broker/balance`
- `GET /v1/broker/payout-profile`
- `PUT /v1/broker/payout-profile`
- `GET /v1/broker/payouts`
- `POST /v1/broker/payouts/queue`

Operator confirmation:

- `POST /operator/v1/broker/payouts/:id/confirm`

The public API remains additive; existing broker order and client pricing contracts are unchanged.
