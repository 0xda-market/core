# Product Documentation

This directory captures the product, marketplace, and user-experience contracts for 0xda-market.

These documents describe how the market is expected to behave from the perspective of clients, brokers, and administrators. They complement the provider-agnostic core architecture under `docs/` and should be treated as product contracts rather than implementation notes.

## Documents

- [Marketplace Product Model](marketplace-product-model.md) — current end-to-end product understanding, including roles, liquidity, broker offers, inventory, pricing, Telegram WebApp entry points, purchase flow, fulfillment, settlement, and MVP boundaries.

## Documentation Contract

Product behavior should be documented here before implementation changes introduce or modify a user-facing contract.

Implementation details may evolve, but the following principles are stable:

- one Telegram bot;
- one Telegram WebApp;
- role-aware entry points;
- broker-provided liquidity;
- products are marketable only while active inventory exists;
- clients and brokers do not need direct contact;
- the core remains provider-agnostic;
- payment, fulfillment, and settlement are separate lifecycle concerns.
