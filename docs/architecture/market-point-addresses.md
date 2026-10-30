# Market point addresses

A Market point is reached at `https://0xda-market.nilx.one/{address}`, for
example `/zoloti`. The address is only a location in Market's URL space. It is
not the point's display name (that is localized, e.g. «Золоті Ворота») and not
its identity in 0x1, which is the station `pub_dress`
`{owner_pub_dress}-{place}` (`0xda-market-zoloti-vorota`). An address may be
shorter than the place, and it names exactly one point, forever.

`market.point_addresses` (migration 028) holds each address with its owner and
place; `market.point_address_aliases` keeps older links working. The author-
seeded Kyiv points of 0xda-market are registered there. Only Golden Gate's
address differs from its place: `zoloti`, with the aliases `zoloti-vorota` and
`золоті`.

## Arrival from 0x1

The 0x1 handoff names the point by its place, as the courier flight ends at
the station. `POST /nilx-browser/handoffs` records the point's address in the
handoff context, and `POST /nilx-browser/exchange` answers `303` to
`/{address}`. A point that is not registered keeps the previous redirect to
`/{point}`, so an unregistered station still lands on Market.

## Resolving a path

`GET /nilx-browser/points` lists every point as
`{ "address", "station_pub_dress", "path" }`.
`GET /nilx-browser/points/{segment}` resolves one decoded path segment: the
address itself (`canonical: true`), or an alias, a station place or an address
in other letter case (`canonical: false`). The browser then replaces the visible
URL with `path`. Anything else is `404 point_not_found`. Both routes are
public: they reveal only what the public point list already shows.
