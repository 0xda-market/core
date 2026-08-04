# Broker order decisions

A marketplace reservation allocates exactly one broker listing. The reservation's `listing_id` is therefore the only authority for broker visibility and action; matching the same SKU in another listing never grants access.

```text
client accepts quote
  -> payment_pending order
  -> requested broker decision for reservation listing owner
  -> broker accepts
  -> trusted payment confirmation
  -> broker completes manual fulfillment
  -> order succeeded
```

The broker workspace reads `GET /v1/broker/orders` and may call:

- `POST /v1/broker/orders/:order_id/accept`;
- `POST /v1/broker/orders/:order_id/complete`.

Both writes require the decision version. Repeated successful transitions are idempotent and report `meta.changed: false`, preventing duplicate channel notifications. Completion requires confirmed payment, claims the existing manual fulfillment task for the allocated seller, completes it and advances the provider-neutral order to `succeeded`.

Buyer identity is not exposed in broker list resources. A successful first transition carries trusted adapter metadata with the internal notification recipient; channel adapters must remove that metadata before returning a browser response.
