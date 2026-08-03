# Mock payment provider

## Purpose

The mock payment provider exercises the real payment-aware marketplace lifecycle without a wallet, blockchain transfer or external acquirer.

It is an adapter inside the `core` repository because it depends on the same provider-neutral order and payment contracts. It is not part of the marketplace domain and is never mounted in production.

```text
API test or development operator
  -> /mock-payments/v1/payment-intents
  -> mock payment provider
  -> Rack callback client
  -> /operator/v1/market/orders/:id/payment/confirm
  -> marketplace payment confirmation
  -> reserved inventory becomes sold
  -> provider-neutral fulfillment starts
```

The callback crosses the existing operator HTTP boundary. The mock provider does not call `Marketplace::Service#confirm_payment` directly.

## Runtime guard

The adapter is mounted only when all of the following are true:

- `DEPLOY_ENV` is not `production`;
- `ENABLE_MOCK_PAYMENT_PROVIDER=1`;
- `MANUAL_PROVIDER_TOKEN` is configured;
- `MOCK_PAYMENT_PROVIDER_TOKEN` is configured.

Starting a production runtime with the mock flag enabled fails immediately. The mock bearer token must not be exposed to browser code.

## API

All routes are mounted below `/mock-payments` and require:

```text
Authorization: Bearer <MOCK_PAYMENT_PROVIDER_TOKEN>
```

### Create an intent

```text
POST /mock-payments/v1/payment-intents
```

```json
{
  "order_id": "ORDER_ID"
}
```

The provider reads the authoritative amount, currency and expiration from the order payment document. The request cannot override commercial terms. Repeating the request for the same order returns the same in-memory intent.

### Read an intent

```text
GET /mock-payments/v1/payment-intents/:id
```

### Simulate success

```text
POST /mock-payments/v1/payment-intents/:id/succeed
```

```json
{
  "reference": "mock-tx-1",
  "data": {
    "scenario": "success"
  }
}
```

Success invokes the authenticated operator confirmation endpoint. Repeating success is idempotent and does not commit inventory twice.

### Simulate failure

```text
POST /mock-payments/v1/payment-intents/:id/fail
```

```json
{
  "code": "declined",
  "message": "declined by test",
  "details": {
    "scenario": "issuer_decline"
  }
}
```

Failure is terminal for the mock intent. It does not falsely confirm the core order, so inventory stays reserved until the core payment deadline is reconciled.

### Simulate provider expiration

```text
POST /mock-payments/v1/payment-intents/:id/expire
```

The mock intent becomes terminal and cannot succeed afterward. Core remains authoritative for the order payment deadline and reservation release.

## State

Mock intent state is process-local by design:

```text
pending -> processing -> succeeded
       \-> failed
       \-> expired
```

A runtime restart removes mock intents but does not remove or alter durable core orders, payment documents, reservations or inventory. A new intent can be created again for a still-pending order.

## Trust boundary

The mock API is an operator/test surface, not a buyer API:

- the browser cannot provide payment amount or currency;
- the browser cannot call the core confirmation endpoint;
- the mock token is separate from the public API token;
- payment confirmation still requires the operator bearer token;
- production cannot mount the mock routes.

A real payment-provider adapter can replace the mock while reusing the same core confirmation boundary and marketplace state machine.
