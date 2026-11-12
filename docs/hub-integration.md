<!-- © 2026 aiaiaiai · aiaiaiai.org -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Market seller: hub.v1 integration boundary

Status: proposed documentation contract; not an implemented or deployed integration.
Canonical protocol: [Prism Hub hub.v1](https://github.com/aiaiaiai-org/prism-hub/pull/74).
AIS peer contract: [4x-ais hub.v1](https://github.com/aiaiaiai-org/4x-ais/pull/9).
Owner decision: 2026-11-12.

## Topology

All cross-service calls and events flow through Prism Hub as a non-retaining
relay, router and orchestrator. Every service knows only Hub's endpoint and
the destination's logical service ID; only Hub resolves target endpoints.
AIS is a peer identity authority, not an upstream gateway.

Hub authenticates the calling service, checks target/operation grants, forwards
the caller identity, and relays the response. The destination still enforces
its own domain authorization. Hub does not durably store request/response
bodies, identity evidence, person passes, event payloads or business state.
It may retain minimal non-sensitive registry/grant/correlation metadata.
Source-owned outboxes and idempotent recipients enable retries; if no owner
can replay an event, Hub must fail explicitly rather than promise delivery.

## Ownership

Market owns catalog, SKUs, quotes, checkout, payment verification and seller-side order state/outbox. It does not own 0x1 Seeds balances, Bond identity or game entitlements.

## Required migration

Request authorized identity provider bindings via Market → Hub → AIS, and player/wallet/subscription claims via Market → Hub → 0x1. Persist seller orders at Market, route order claims to issuer through Hub, and relay signed source events. No direct 0x1/Market handoff after migration.

## Acceptance gates

- No new direct cross-product service endpoints, shared databases or cookies.
- Service identity, recipient grants and operation scopes validated at Hub;
  target rechecks domain authorization and one-time recipient passes.
- Hub does not persist payloads or log secrets; owner-controlled outboxes
  handle replay and recipients deduplicate events/orders.
- Contract tests cover denied grants, unavailable destinations, duplicate
  deliveries and recovery after Hub restart.
- Migration is a separate implementation PR; preserve working legacy routes
  until verified cutover. No implicit checkout activation, merge or deploy.
