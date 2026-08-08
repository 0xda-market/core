-- Keep the buyer-facing catalog intentionally small and make the purchase
-- semantics explicit in product metadata. Currency rows remain platform
-- reference data (marketable=false) and therefore are not buyer products.
--
-- This migration is deliberately recovery-safe. Development/test environments
-- may have had catalog rows cleared while retaining schema_migrations. Rebuild
-- the six canonical Telegram products before inserting localizations so a
-- partially emptied catalog cannot violate the localization foreign key.

-- Positions are globally unique. Free the buyer slots before restoring the
-- canonical six products; historical rows keep their relative order outside
-- the buyer range.
UPDATE market.products
SET position = position + 1000,
    updated_at = now(),
    version = version + 1
WHERE position BETWEEN 1 AND 6;

INSERT INTO market.products (
  sku, short_name, metadata, status, position, created_at, updated_at,
  version, marketable, name, button_label
)
VALUES
  (
    'premium_3m', 'Premium 3m',
    '{"family":"telegram_premium","duration_months":3,"purchase":{"quantity_mode":"single","recipient":{"provider":"telegram","modes":["self","username"],"eligibility":{"is_premium":false},"ineligible_code":"premium_already_active"}}}'::jsonb,
    'active', 1, now(), now(), 0, true,
    'Telegram Premium 3 months', 'Premium 3m'
  ),
  (
    'premium_6m', 'Premium 6m',
    '{"family":"telegram_premium","duration_months":6,"purchase":{"quantity_mode":"single","recipient":{"provider":"telegram","modes":["self","username"],"eligibility":{"is_premium":false},"ineligible_code":"premium_already_active"}}}'::jsonb,
    'active', 2, now(), now(), 0, true,
    'Telegram Premium 6 months', 'Premium 6m'
  ),
  (
    'premium_9m', 'Premium 9m',
    '{"family":"telegram_premium","duration_months":9,"purchase":{"quantity_mode":"single","recipient":{"provider":"telegram","modes":["self","username"],"eligibility":{"is_premium":false},"ineligible_code":"premium_already_active"}}}'::jsonb,
    'active', 3, now(), now(), 0, true,
    'Telegram Premium 9 months', 'Premium 9m'
  ),
  (
    'stars_500', 'Stars 500',
    '{"family":"telegram_stars","amount":500,"purchase":{"quantity_mode":"single","recipient":{"provider":"telegram","modes":["self","username"]}}}'::jsonb,
    'active', 4, now(), now(), 0, true,
    'Telegram Stars 500', 'Stars 500'
  ),
  (
    'stars_1000', 'Stars 1000',
    '{"family":"telegram_stars","amount":1000,"purchase":{"quantity_mode":"single","recipient":{"provider":"telegram","modes":["self","username"]}}}'::jsonb,
    'active', 5, now(), now(), 0, true,
    'Telegram Stars 1000', 'Stars 1000'
  ),
  (
    'stars_3000', 'Stars 3000',
    '{"family":"telegram_stars","amount":3000,"purchase":{"quantity_mode":"single","recipient":{"provider":"telegram","modes":["self","username"]}}}'::jsonb,
    'active', 6, now(), now(), 0, true,
    'Telegram Stars 3000', 'Stars 3000'
  )
ON CONFLICT (sku) DO UPDATE SET
  short_name = EXCLUDED.short_name,
  metadata = market.products.metadata || EXCLUDED.metadata,
  status = 'active',
  position = EXCLUDED.position,
  marketable = true,
  name = EXCLUDED.name,
  button_label = EXCLUDED.button_label,
  updated_at = now(),
  version = market.products.version + 1;

-- The old 12-month SKU and crypto assets stay as historical catalog records,
-- but cannot appear in the buyer market or accept new broker supply.
UPDATE market.products
SET status = 'inactive', marketable = false, updated_at = now(), version = version + 1
WHERE sku IN ('premium_12m', 'ton', 'btc', 'eth');

INSERT INTO market.product_localizations (
  product_sku, locale, full_name, button_label, created_at, updated_at, version
)
VALUES
  ('premium_3m', 'en_US', 'Telegram Premium 3 months', 'Premium 3m', now(), now(), 0),
  ('premium_3m', 'uk_UA', 'Telegram Premium 3 міс.', 'Premium 3 міс.', now(), now(), 0),
  ('premium_3m', 'ru_RU', 'Telegram Premium на 3 месяца', 'Premium 3 мес.', now(), now(), 0),
  ('premium_6m', 'en_US', 'Telegram Premium 6 months', 'Premium 6m', now(), now(), 0),
  ('premium_6m', 'uk_UA', 'Telegram Premium 6 міс.', 'Premium 6 міс.', now(), now(), 0),
  ('premium_6m', 'ru_RU', 'Telegram Premium на 6 месяцев', 'Premium 6 мес.', now(), now(), 0),
  ('premium_9m', 'en_US', 'Telegram Premium 9 months', 'Premium 9m', now(), now(), 0),
  ('premium_9m', 'uk_UA', 'Telegram Premium 9 міс.', 'Premium 9 міс.', now(), now(), 0),
  ('premium_9m', 'ru_RU', 'Telegram Premium на 9 месяцев', 'Premium 9 мес.', now(), now(), 0),
  ('stars_500', 'en_US', 'Telegram Stars 500', 'Stars 500', now(), now(), 0),
  ('stars_500', 'uk_UA', 'Telegram Stars 500', 'Stars 500', now(), now(), 0),
  ('stars_500', 'ru_RU', 'Telegram Stars 500', 'Stars 500', now(), now(), 0),
  ('stars_1000', 'en_US', 'Telegram Stars 1000', 'Stars 1000', now(), now(), 0),
  ('stars_1000', 'uk_UA', 'Telegram Stars 1000', 'Stars 1000', now(), now(), 0),
  ('stars_1000', 'ru_RU', 'Telegram Stars 1000', 'Stars 1000', now(), now(), 0),
  ('stars_3000', 'en_US', 'Telegram Stars 3000', 'Stars 3000', now(), now(), 0),
  ('stars_3000', 'uk_UA', 'Telegram Stars 3000', 'Stars 3000', now(), now(), 0),
  ('stars_3000', 'ru_RU', 'Telegram Stars 3000', 'Stars 3000', now(), now(), 0)
ON CONFLICT (product_sku, locale) DO UPDATE SET
  full_name = EXCLUDED.full_name,
  button_label = EXCLUDED.button_label,
  updated_at = now(),
  version = market.product_localizations.version + 1;

-- The requested buyer-facing language set is en/uk/ru. Other translations
-- fall back to English instead of maintaining stale copy for these six SKUs.
DELETE FROM market.product_localizations
WHERE product_sku IN (
  'premium_3m', 'premium_6m', 'premium_9m',
  'stars_500', 'stars_1000', 'stars_3000'
)
AND locale NOT IN ('en_US', 'uk_UA', 'ru_RU');
