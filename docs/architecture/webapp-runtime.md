# WebApp runtime architecture

The WebApp surface has three peer repositories with one dependency direction:

```text
telegram-bot/webapp -> webapp-core -> core JSON APIs
```

[webapp-core](https://github.com/0xda-market/webapp-core) owns the browser-native catalog engine, immutable snapshot state, local search and pagination, checkout state machine and reusable role-driven UI.

[telegram-bot](https://github.com/0xda-market/telegram-bot) owns the Telegram SDK host, signed `initData` transport, HTML/CSS shell, BFF and deployment entry point. It consumes an exact immutable `webapp-core` revision.

`core` owns only provider-agnostic domain and backend contracts. It does not package or serve browser modules or a standalone WebApp.

## Complete snapshot contract

`GET /v1/webapp/bootstrap` remains a core API and returns every active sellable product for one locale and presentation currency in a single response. Its `meta` contract includes `schema_version`, `snapshot_id`, `generated_at`, `count`, `available_count`, `complete: true`, `pagination: client`, `locale` and `currency`.

A product is buyer-available only when both conditions hold at snapshot generation time:

- an applied client price exists;
- at least one active broker listing has available inventory.

The snapshot emits `attributes.available` explicitly and omits the public price when either condition is false. Broker identity, supply price and inventory allocation details remain private. Quote creation still revalidates price and liquidity transactionally, so the snapshot is presentation state rather than settlement authority.

The public snapshot excludes internal audit identities. Browsing state is not settlement authority: quote, acceptance and order operations always revalidate current server state.

## Delivery contract

Core serves JSON APIs only. Browser assets are released from `webapp-core` and mounted by a channel host. Production hosts must pin an immutable commit or released package version; default-branch URLs are not a supported dependency.
