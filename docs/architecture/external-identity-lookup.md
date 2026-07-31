# External identity lookup

Channel adapters sometimes receive an external identity reference while privileged core operations require a stable internal `market.users.id`.

The protected lookup endpoint is:

```text
GET /v1/admin/users/by-external-identity
```

It requires the normal public API bearer token and an `actor_user_id` whose persisted role is `admin`.

## Selectors

Every request supplies `provider` and exactly one selector:

```text
provider_user_id=<external provider identifier>
```

or:

```text
provider_data_key=<opaque provider data key>
provider_data_value=<opaque provider data value>
case_insensitive=true|false
```

`case_insensitive` is valid only for provider-data lookup and defaults to `false`. The core validates selector shape but does not interpret provider names, data keys or values.

The response is one provider-neutral user profile containing the internal UUID, role, status and all linked external identities. Lookup does not enumerate active users and does not filter by user status. The subsequent privileged operation remains authoritative about whether the resolved user is eligible; for example, administrator assignment still rejects a blocked target.

Provider-data fields are not required to be globally unique. If a selector matches more than one external identity, core fails closed with `ambiguous_external_identity` instead of choosing an arbitrary user. Channel adapters may then require a stable provider user ID.

## Boundary

The channel adapter translates its user-facing reference into this generic lookup contract. It then sends the returned internal UUID to the existing operation, such as:

```text
POST /v1/admin/users/set-admin
```

The lookup endpoint does not assign roles, authenticate users or introduce channel-specific concepts into the domain model.
