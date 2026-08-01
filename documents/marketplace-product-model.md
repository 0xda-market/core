# 0xda-market Marketplace Product Model

## Status

This document captures the current product and marketplace model for 0xda-market. It is the working contract for the first Telegram WebApp implementation.

The initial market is Telegram Premium, but the design must support additional digital products and assets without rebuilding the marketplace around a single provider.

## Product Thesis

0xda-market is a two-sided marketplace that connects client demand with broker-provided supply.

The platform does not manufacture inventory and should not expose brokers and clients to one another. Its value is the market layer between them:

- brokers publish what they can sell, at what source price, and in what quantity;
- clients see a normalized catalog with final prices;
- the platform reserves inventory, accepts payment, coordinates fulfillment, and settles proceeds;
- the platform and the broker share the margin created between the broker's source price and the client's final price.

Telegram Premium is the first product family and a proving ground for this market model.

## Operating Example

A broker may have access to Telegram Premium inventory at source prices such as:

- three months for 520 RUB;
- six months for 800 RUB;
- twelve months for 1,200 RUB.

A European client may see final prices denominated in EUR, such as EUR 5, EUR 8, and EUR 12, or another price produced by the pricing engine.

The client price is not a direct currency conversion. It includes a controlled margin. A simple initial model may place the client price halfway between the broker's source price and an administrator-defined market reference price after currency normalization.

The exact pricing formula is configurable and must not be embedded in the product catalog or Telegram UI.

## One Bot, One WebApp

0xda-market uses one Telegram bot and one Telegram WebApp.

The bot is the identity, notification, and navigation surface. The WebApp is the transactional marketplace interface.

There are no separate client and broker bots. There are no separate client and broker WebApps.

Instead, the same WebApp supports multiple role-aware entry points opened by different buttons in the bot.

### Client entry point

The **Buy** button opens the client catalog.

This entry point is available to every authenticated user.

### Broker entry point

The **Add Offer** button opens the broker offer creation flow.

This entry point is available only to approved brokers and administrators.

### Administrative entry point

The **Manage** button opens administrative operations.

This entry point is available only to administrators.

Entry points select the initial WebApp route. They do not grant authorization. The backend validates Telegram WebApp `initData`, resolves the internal user, and enforces permissions for every operation.

Recommended initial routes are:

- `/market` for the client catalog;
- `/offers/new` for offer creation;
- `/offers` for the broker's active and historical offers;
- `/orders` for purchase and sale activity;
- `/admin` for administrative operations.

## Capability Hierarchy

The role model is cumulative:

**admin includes broker, and broker includes client.**

A role represents a capability tier, not an exclusive persona.

### Client

Every authenticated user is a client and can:

- browse marketable products;
- create a purchase;
- pay for an order;
- receive a product;
- inspect purchase history.

### Broker

An approved broker has the complete client flow and can additionally:

- publish product offers;
- set source price, currency, quantity, and availability;
- update or pause offers;
- receive assigned sales;
- fulfill orders;
- accrue and withdraw broker proceeds.

A broker remains a client and can buy products through the same bot and WebApp.

### Administrator

An administrator has the complete broker and client flows and can additionally:

- approve or reject broker applications;
- define and maintain product types;
- maintain product localization;
- maintain pricing references and pricing rules;
- review suspicious offers;
- pause offers or users;
- manage disputes;
- inspect market and settlement operations.

An administrator may publish offers like any broker, but is not required to sell inventory. Administrative capability does not imply active supply.

## Broker Enrollment

A client may submit a **Become a Broker** request from the Telegram bot.

The request enters a pending state and is visible to administrators.

An administrator may approve or reject the request.

Approval upgrades the user's capability tier from client to broker. Rejection leaves the user as a client.

Authentication itself must never grant broker or administrator capability.

## Products and Offers

The marketplace must distinguish the product definition from a broker's sellable offer.

### Product

A product describes what can be traded.

Examples include:

- Telegram Premium for three months;
- Telegram Premium for six months;
- Telegram Premium for twelve months;
- Telegram Stars;
- TON;
- other future digital assets.

The product owns stable identity, localization, display metadata, status, and product-specific rules.

A product does not represent available inventory by itself.

### Broker offer

A broker offer describes a broker's current commitment to sell a product.

Each offer includes at minimum:

- broker identity;
- product identity;
- source price;
- source currency;
- total quantity;
- available quantity;
- reserved quantity;
- sold quantity;
- status;
- validity window or last-confirmed timestamp;
- expected fulfillment time;
- optional fulfillment metadata.

The canonical domain term is **broker offer**. The primary UI label should be **My Offers**.

The phrase "broker exchange" should not be used as the domain term because the exchange is the aggregate market, not an individual broker's inventory.

## Marketability and Liquidity

A product is marketable only while at least one eligible broker offer has available inventory.

An offer is eligible when it is:

- active;
- within its validity window;
- owned by an approved and active broker;
- priced in a supported currency;
- above zero available quantity;
- not administratively blocked.

The client catalog is therefore derived from live broker liquidity.

If every eligible offer for a product is exhausted, expired, paused, or blocked, the product becomes unavailable to clients. The UI may hide it or display it as unavailable, but it must not accept a purchase.

## Broker Inventory Lifecycle

A broker publishes inventory through a flow structurally similar to the client purchase flow:

1. select a product;
2. enter the source price;
3. select the source currency;
4. enter quantity;
5. define availability or validity;
6. review the offer;
7. publish.

The broker can later:

- change price;
- increase quantity;
- decrease unreserved quantity;
- refresh the offer's validity;
- pause the offer;
- resume the offer;
- mark inventory as sold out.

An offer must preserve transaction history. Updating a live offer must not rewrite historical orders or their captured economics.

When all units are sold, available quantity reaches zero and the offer stops contributing liquidity. The broker may replenish or republish it.

## Client Catalog

Clients do not browse individual brokers.

The WebApp aggregates eligible broker offers into one normalized product card per product.

The client sees:

- product name and localized description;
- duration or denomination;
- final client price;
- display currency;
- available purchase quantity, when relevant;
- expected delivery time;
- product status.

The client does not see:

- broker identity;
- broker source price;
- the broker's total inventory;
- competing broker offers;
- platform margin;
- broker margin share.

The marketplace selects the offer or offer sequence used to fulfill the order.

## Offer Selection

The first implementation may select the lowest eligible normalized source price.

The selection contract should remain extensible for additional factors:

- effective source price after currency conversion;
- broker reliability;
- fulfillment speed;
- remaining quantity;
- offer freshness;
- failure rate;
- administrative priority;
- concentration limits.

Selection must be deterministic for equivalent inputs and must not depend on Telegram presentation order.

## Pricing

Pricing has three distinct values:

1. the broker's source price;
2. the client's final price;
3. the settlement split between broker proceeds and platform revenue.

These values must be stored independently.

### Source price

The source price is the amount declared by the broker for one unit of the product in the broker's source currency.

### Client price

The client price is calculated by the pricing engine after normalizing the source price into a reference currency and applying market rules.

The first pricing strategy may use an administrator-maintained market reference and split the spread between the normalized source price and that reference.

Conceptually:

- normalize the broker source price;
- compare it with the current market reference;
- calculate the available spread;
- apply the configured client pricing rule;
- add payment and operational costs when required;
- round according to display-currency rules.

The price shown to the client must be captured when inventory is reserved. Later currency or pricing changes must not mutate an existing reservation or paid order.

### Margin and settlement

Gross margin is the client payment less the captured broker cost and direct transaction costs.

The broker receives the captured source-price amount plus the configured broker share of margin, unless a different settlement contract is explicitly selected.

The platform receives the remaining margin.

The split must be explicit, versioned, and captured on each order. It must not be recalculated from current configuration after the order is placed.

## Inventory Reservation

Inventory must be reserved before a client is allowed to complete payment.

A reservation atomically moves quantity from available to reserved.

For example, if an offer has three available units and a client begins checkout for one unit, the offer must immediately report two available units and one reserved unit.

A reservation has an expiration time.

If payment succeeds, the reservation becomes committed inventory for the order.

If payment fails, is canceled, or times out, the reserved quantity returns to available inventory.

This contract prevents overselling and must be enforced transactionally in persistence.

## Client Purchase Flow

The initial client flow is:

1. authenticate through Telegram;
2. open the **Buy** entry point;
3. browse products backed by active liquidity;
4. select a product and quantity;
5. receive a captured final price;
6. reserve broker inventory;
7. complete checkout;
8. wait for fulfillment;
9. receive the asset or redemption instrument;
10. confirm or automatically verify delivery;
11. complete the order.

A screenshot or a client-provided "I paid" action is not payment confirmation. Payment state must be established by a trusted provider callback or another verifiable settlement event.

## Payment Boundary

The Telegram bot and WebApp coordinate checkout but are not themselves the payment ledger.

The payment adapter may support:

- Telegram-native payment instruments where product and platform rules permit them;
- external card checkout;
- bank or regional payment rails;
- supported crypto settlement;
- future payment providers.

The core payment contract must remain provider-agnostic.

An order is paid only after a verified payment event is recorded.

Payment, inventory, fulfillment, and broker payout are separate states. A successful payment does not imply successful delivery, and successful delivery does not imply that broker payout has already been released.

## Fulfillment

The initial Telegram Premium flow may use either direct gifting or a redeemable gift code, depending on what the broker can reliably provide.

### Gift-code fulfillment

Gift-code fulfillment is preferred when available because it better isolates the parties.

The broker acquires a valid Telegram Premium gift code or redemption link and submits it through the broker flow in the same WebApp or bot.

The platform validates the submitted instrument as far as the Telegram integration permits, associates it with the order, and delivers it to the client.

The client activates the gift without learning the broker's identity.

### Direct-gift fulfillment

When a gift code is not available, a broker may fulfill through a direct Telegram Premium gift using a regular Telegram client or a future controlled fulfillment worker.

Direct gifting may require recipient identity to be disclosed to the fulfilling account. This is a weaker privacy boundary and should be treated as a fallback, not the preferred marketplace contract.

### Manual first, automated later

The MVP may use manual broker fulfillment coordinated by the platform.

The broker accepts an assigned sale, acquires or transfers the product, submits fulfillment evidence or the redemption instrument, and marks the task complete.

A later version may automate execution through provider-specific workers. That automation must remain behind the generic fulfillment port and must not leak Telegram-specific logic into the core marketplace model.

## Order Lifecycle

The lifecycle should distinguish at least:

- created;
- inventory reserved;
- payment pending;
- paid;
- broker assigned;
- fulfillment in progress;
- delivered;
- verified;
- settled;
- canceled;
- failed;
- disputed;
- refunded.

State transitions must be idempotent and auditable.

The implementation may map these product states to the existing generic intent, quote, order, and provider-execution contracts, but it must preserve the marketplace meaning described here.

## Broker Assignment

A paid order is assigned to the broker offer whose inventory was reserved, unless the system explicitly supports reassignment.

If the broker cannot fulfill within the deadline, the system may:

- reassign against another eligible offer;
- preserve the client's captured price;
- record any platform loss or margin change;
- release or penalize the failed broker reservation;
- escalate the order to an administrator.

Reassignment must never silently charge the client again.

## Settlement and Broker Balance

Client funds are not released to the broker immediately after the broker presses a completion button.

Broker proceeds move through separate balance states:

- pending fulfillment;
- pending verification;
- available for payout;
- paid out;
- withheld or reversed.

The first version may batch broker payouts or require a minimum payout balance.

Every balance mutation must reference the originating order and preserve an append-only audit trail.

## Privacy Boundary

The marketplace should prevent unnecessary direct contact between clients and brokers.

The client should not receive broker contact information.

The broker should not receive client contact information unless the selected fulfillment method technically requires a recipient identifier.

Where possible, sensitive delivery data should be passed to a controlled fulfillment adapter rather than displayed to the broker.

The bot and WebApp should use internal user and order identifiers in product flows. Telegram identifiers are adapter-level identity data.

## Administrative Pricing

Administrators maintain the market inputs used by the pricing engine. This may include:

- currency conversion references;
- external retail reference prices;
- minimum and maximum client prices;
- minimum margin;
- broker margin share;
- payment-cost allowances;
- rounding rules;
- product-specific overrides.

Administrators do not make a product available merely by entering a price. Supply still requires at least one eligible broker offer with available quantity.

Administrative prices are market references and policy inputs, not inventory.

## WebApp MVP

The first WebApp release must implement both sides of the marketplace.

### Client surface

The client surface includes:

- localized catalog;
- product details;
- price quote;
- quantity selection where applicable;
- checkout handoff;
- order status;
- delivery or redemption;
- purchase history.

### Broker surface

The broker surface includes:

- offer creation;
- My Offers;
- price and quantity updates;
- pause, resume, refresh, and sold-out actions;
- assigned sales;
- fulfillment submission;
- balance and transaction history.

### Bot surface

The Telegram bot includes role-aware buttons:

For clients:

- **Buy**;
- **Become a Broker**;
- order and profile actions as needed.

For brokers:

- **Buy**;
- **Add Offer**;
- broker application controls are no longer shown;
- order, offer, balance, and profile actions as needed.

For administrators:

- all client and broker actions;
- **Manage**;
- broker-application review notifications and actions.

The WebApp may offer internal navigation after launch, but the bot buttons remain distinct entry points into the same application.

## Initial Data Model

The product model is expected to require the following concepts, whether represented by dedicated tables or equivalent domain records:

- users and external identities;
- cumulative capability or role state;
- broker applications;
- products;
- product localizations;
- administrator-maintained price references;
- broker offers;
- offer inventory and inventory movements;
- reservations;
- client quotes;
- orders;
- payments;
- fulfillment records;
- broker balance entries;
- payouts;
- disputes and refunds;
- append-only audit events.

The exact schema must follow existing repository conventions and preserve provider-agnostic core boundaries.

## Invariants

The implementation must preserve these invariants:

1. Every broker and administrator can use the complete client flow.
2. Every administrator can use the complete broker flow.
3. A product cannot be purchased without eligible available broker inventory.
4. Administrative pricing does not create inventory.
5. Inventory cannot be sold twice.
6. Reserved inventory has a bounded lifetime.
7. Payment confirmation comes from a trusted verification path.
8. Broker completion alone does not release payout.
9. Historical order economics are immutable.
10. Client and broker identities remain isolated unless fulfillment strictly requires disclosure.
11. Telegram is an adapter and entry surface, not the core domain.
12. Product-specific fulfillment does not compromise the provider-agnostic marketplace core.

## Explicit Non-Goals for the First Release

The first release does not need:

- a public order book;
- direct client selection of brokers;
- real-time broker bidding;
- multiple standalone WebApps;
- separate client and broker bots;
- fully automated Telegram user-account execution;
- unrestricted peer-to-peer messaging;
- advanced dynamic pricing or market making;
- production deployment as part of the documentation change.

## Open Decisions

The following decisions require later product or implementation work:

- the first supported payment provider and settlement currency;
- the exact pricing formula and broker margin share;
- Telegram Premium gift-code sourcing and validation capabilities;
- fulfillment verification rules;
- reservation and fulfillment timeouts;
- payout rail and payout schedule;
- dispute and refund policy;
- broker risk scoring and limits;
- catalog behavior for temporarily unavailable products;
- whether one order may aggregate inventory from multiple offers.

These are implementation inputs, not reasons to weaken the stable marketplace contracts in this document.
