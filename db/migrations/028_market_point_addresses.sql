-- © 2026 aiaiaiai · aiaiaiai.org
-- SPDX-License-Identifier: MIT
--
-- Public addresses of Market points: https://0xda-market.nilx.one/{address}.
-- An address is only a location in Market's own URL space, not a display name
-- and not the station's identity. A station is `{owner_pub_dress}-{place}` in
-- 0x1 (for example `0xda-market-zoloti-vorota`); its address may be shorter
-- (`zoloti`). An address or alias names exactly one point, forever.
--
-- Aliases keep older links working: they resolve to the canonical address,
-- and the browser replaces the visible URL with it.
CREATE TABLE market.point_addresses (
  address text PRIMARY KEY
    CHECK (length(address) <= 48 AND address ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  owner_pub_dress text NOT NULL
    CHECK (length(owner_pub_dress) <= 64 AND owner_pub_dress ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  place text NOT NULL
    CHECK (length(place) <= 64 AND place ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (owner_pub_dress, place)
);

CREATE TABLE market.point_address_aliases (
  alias text PRIMARY KEY
    CHECK (length(alias) BETWEEN 1 AND 64 AND alias !~ '[/?#%[:space:][:cntrl:]]'),
  address text NOT NULL REFERENCES market.point_addresses(address)
);

-- The author-seeded 0xda-market points of Kyiv (nilx-one/web
-- docs/market-points.md). Only Golden Gate's address differs from its place.
INSERT INTO market.point_addresses (address, owner_pub_dress, place) VALUES
  ('zoloti', '0xda-market', 'zoloti-vorota'),
  ('batkivshchyna', '0xda-market', 'batkivshchyna'),
  ('peizazhna-aleia', '0xda-market', 'peizazhna-aleia'),
  ('cosmopolite', '0xda-market', 'cosmopolite'),
  ('gorodok-gallery', '0xda-market', 'gorodok-gallery'),
  ('smart-plaza-polytech', '0xda-market', 'smart-plaza-polytech'),
  ('raion', '0xda-market', 'raion'),
  ('mandarin-plaza', '0xda-market', 'mandarin-plaza'),
  ('respublika-park', '0xda-market', 'respublika-park'),
  ('lavina-mall', '0xda-market', 'lavina-mall'),
  ('river-mall', '0xda-market', 'river-mall'),
  ('retroville', '0xda-market', 'retroville'),
  ('tsum', '0xda-market', 'tsum'),
  ('skymall', '0xda-market', 'skymall'),
  ('dream-berry', '0xda-market', 'dream-berry'),
  ('dream-yellow', '0xda-market', 'dream-yellow'),
  ('gulliver', '0xda-market', 'gulliver'),
  ('osokorky', '0xda-market', 'osokorky'),
  ('pozniaky', '0xda-market', 'pozniaky'),
  ('troieshchyna-centre', '0xda-market', 'troieshchyna-centre'),
  ('livoberezhna', '0xda-market', 'livoberezhna'),
  ('petra-zaporozhtsia', '0xda-market', 'petra-zaporozhtsia');

INSERT INTO market.point_address_aliases (alias, address) VALUES
  ('zoloti-vorota', 'zoloti'),
  ('золоті', 'zoloti');
