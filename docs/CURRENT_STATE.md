# Current project state

This document summarizes the implemented 0xda-market core contract as of 2026-08-07. Architecture documents remain authoritative for individual boundaries; this page is the cross-cutting snapshot.

## Market authority

The administrator-owned product price is the buyer-facing commercial price. Broker asks do not raise the client price.

A broker listing is executable only when its normalized USDT supply cost satisfies the configured marketplace margin, variable execution cost, fixed execution cost, and supply buffer. Supply that fails this gate remains visible to broker/admin surfaces but cannot be reserved for a client quote.

## Broker incentive and routing

Eligible broker supply is ranked privately by normalized executable cost. Exact competitor asks are never exposed.

Routing currently uses deterministic traffic tiers:

- one eligible broker: 100%;
- two eligible brokers: 80% / 20%;
- three or more eligible brokers: 70% / 20% / 10% for the top three executable offers.

Lowering a broker ask can therefore improve routing rank and expected order share without changing the price shown to the client.

## FX and localized client pricing

Localized pricing is a two-step server-owned sequence:

1. **FX acquisition:** a dedicated refresh process fetches a USDT-based Coinbase exchange-rate snapshot, validates it, converts it into the internal `USDT per currency unit` contract, and persists it atomically with provider provenance.
2. **Presentation:** core performs exact conversion from the authoritative USDT price and then applies the configured currency-aware upward rounding strategy.

API requests never call the external FX provider directly. Persisted non-USDT rates fail closed after the freshness TTL; USDT remains fixed at 1.

The supported localized-pricing currency set currently includes USDT, EUR, GBP, CHF, PLN, CZK, and HUF. Language selection and currency selection are separate concerns.

## Catalog and localization

The product catalog is database-backed and localized independently from locale-neutral product state. `en_US` is the canonical fallback. The current catalog localization matrix covers the primary supported application languages and regional fallbacks while preserving stable SKUs and category identifiers.

A product can be listed but not executable: `listed` means active broker inventory exists, while `available` means core can safely quote it under pricing, FX freshness, inventory, and positive-margin gates.

## Browser and channel boundaries

`core` owns products, users, roles, prices, FX, broker listings, reservations, quotes, orders, payment state, profitability, and routing policy.

`0xda-market/webapp-core` owns reusable browser state and interaction flows. Channel repositories such as `0xda-market/telegram-bot` own authentication, signed host transport, shell presentation, messenger SDK integration, and deployment entry points.

The browser renders authoritative server amounts. It does not calculate FX, profitability, broker ranking, allocation, inventory balances, or payment confirmation.

## Delivery state

The implemented path includes:

- database-backed products and localizations;
- append-only administrator price history;
- broker-owned finite inventory listings;
- reservation-aware quantity accounting;
- fixed client pricing with profitability gating;
- private broker supply routing;
- automated FX acquisition and freshness enforcement;
- localized client price presentation;
- quote, acceptance, payment-pending, fulfillment, and refresh lifecycle surfaces;
- role-gated Telegram Mini App workspaces.

Payment-provider settlement, broker payout accounting, refunds/disputes, and automated provider-specific fulfillment remain separate future adapters/contracts rather than browser-owned behavior.
