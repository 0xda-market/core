-- Provider-managed FX rates use the existing append-only product price model,
-- with enough precision for low-value fiat units and an auditable provider key.
ALTER TABLE market.product_prices
  DROP CONSTRAINT product_prices_source_check,
  ADD CONSTRAINT product_prices_source_check
    CHECK (
      source IN ('admin', 'core') OR
      source ~ '^fx:[a-z0-9][a-z0-9._-]{0,63}$'
    ),
  ALTER COLUMN amount_usdt TYPE numeric(24, 12);

ALTER TABLE market.products
  ALTER COLUMN current_price_usdt TYPE numeric(24, 12);

INSERT INTO market.products (
  sku, short_name, metadata, status, position, marketable, name, button_label
)
VALUES
  ('eur', 'EUR', '{"family":"currency","code":"EUR","symbol":"€","scale":2}'::jsonb, 'active', 104, false, 'Євро', 'EUR'),
  ('gbp', 'GBP', '{"family":"currency","code":"GBP","symbol":"£","scale":2}'::jsonb, 'active', 105, false, 'Британський фунт', 'GBP'),
  ('chf', 'CHF', '{"family":"currency","code":"CHF","symbol":"CHF","scale":2}'::jsonb, 'active', 106, false, 'Швейцарський франк', 'CHF'),
  ('pln', 'PLN', '{"family":"currency","code":"PLN","symbol":"zł","scale":2}'::jsonb, 'active', 107, false, 'Польський злотий', 'PLN'),
  ('czk', 'CZK', '{"family":"currency","code":"CZK","symbol":"Kč","scale":2}'::jsonb, 'active', 108, false, 'Чеська крона', 'CZK'),
  ('huf', 'HUF', '{"family":"currency","code":"HUF","symbol":"Ft","scale":2}'::jsonb, 'active', 109, false, 'Угорський форинт', 'HUF');

INSERT INTO market.product_localizations (
  product_sku, locale, full_name, button_label, created_at, updated_at, version
)
VALUES
  ('eur', 'en_US', 'Euro', 'EUR', now(), now(), 0),
  ('eur', 'uk_UA', 'Євро', 'EUR', now(), now(), 0),
  ('gbp', 'en_US', 'British Pound', 'GBP', now(), now(), 0),
  ('gbp', 'uk_UA', 'Британський фунт', 'GBP', now(), now(), 0),
  ('chf', 'en_US', 'Swiss Franc', 'CHF', now(), now(), 0),
  ('chf', 'uk_UA', 'Швейцарський франк', 'CHF', now(), now(), 0),
  ('pln', 'en_US', 'Polish Zloty', 'PLN', now(), now(), 0),
  ('pln', 'uk_UA', 'Польський злотий', 'PLN', now(), now(), 0),
  ('czk', 'en_US', 'Czech Koruna', 'CZK', now(), now(), 0),
  ('czk', 'uk_UA', 'Чеська крона', 'CZK', now(), now(), 0),
  ('huf', 'en_US', 'Hungarian Forint', 'HUF', now(), now(), 0),
  ('huf', 'uk_UA', 'Угорський форинт', 'HUF', now(), now(), 0);
