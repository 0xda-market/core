# WebApp runtime architecture

The WebApp surface consists of three entities with one dependency direction:

```text
webapp-core
  ├─ standalone webapp
  └─ telegram-bot/webapp
```

`webapp-core` is a browser-native ES module. It owns snapshot validation, immutable catalog state, local search, local filtering, viewport page sizing, local pagination and the checkout state machine. It contains no Telegram SDK code, bot token, market API token, HTTP server or deployment logic.

The standalone WebApp lives under `webapp/` and is served at `/app/`. The Telegram Mini App is owned by `0xda-market/telegram-bot` and imports the same `/webapp-core/index.js` module.

## Complete snapshot contract

`GET /v1/webapp/bootstrap` returns every active sellable product for one locale and presentation currency in a single response:

```text
open WebApp
  -> one bootstrap request
  -> immutable product snapshot
  -> all page, category, search and viewport changes in memory
```

The response meta contract is:

- `schema_version` — bootstrap schema version;
- `snapshot_id` — SHA-256 of the complete product resource array;
- `generated_at` — response creation time;
- `count` — number of loaded products;
- `complete: true` — no server-side continuation exists;
- `pagination: client` — pages are array slices in `webapp-core`;
- `locale` and `currency` — presentation context.

The public snapshot excludes internal user UUIDs used for product and price auditing. Existing authenticated `/v1/products` behavior remains unchanged.

## Pagination invariant

A snapshot with 1,488 products and a portrait page size of six has 248 local pages. Moving from page one to page two or page three performs no HTTP request. Portrait uses six products per page; landscape uses twelve, or eighteen on wide landscape displays. Resizing preserves the first visible product.

Network calls are allowed only for explicit lifecycle actions:

```text
select product locally
  -> request current quote
  -> explicit accept
  -> create/execute order
  -> explicit order refresh
```

Core revalidates product status, price, quote expiry and order ownership at those boundaries. The loaded snapshot is a browsing contract, not authority for settlement.

## Static delivery

The core runtime serves:

- `/webapp-core/index.js` — shared browser engine;
- `/app/` — standalone shell;
- `/v1/webapp/bootstrap` — complete catalog snapshot.

Assets are cacheable. Catalog bootstrap is intentionally a fresh snapshot request on WebApp opening; the browser does not request additional catalog pages afterward.
