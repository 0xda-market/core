-- Initial 0x1 Bond subscriptions (catalog and one-time introductory prices).
-- Product discovery is staged; runtime fulfillment, settlement, and authority-
-- backed entitlement/Seeds debit are NOT yet implemented. Do not activate the
-- SKUs merely because this migration has been applied.
--
-- USDT prices are appended to the canonical price history, not copied into
-- metadata. SEED (display symbol: ₴€£) is 0x1's game currency, NOT UAH/EUR/GBP
-- and must never be routed through the market's fiat FX machinery.

WITH subscription_seed (sku, tier, duration_months, usdt, seeds, ordinal) AS (
  VALUES
    ('0x1_special_1m', 'special', 1, 2.49, 400, 1),
    ('0x1_special_3m', 'special', 3, 6.29, 1020, 2),
    ('0x1_special_6m', 'special', 6, 11.49, 1800, 3),
    ('0x1_special_12m', 'special', 12, 14.99, 2400, 4),
    ('0x1_exclusive_1m', 'exclusive', 1, 5.49, NULL, 5),
    ('0x1_exclusive_3m', 'exclusive', 3, 13.99, NULL, 6),
    ('0x1_exclusive_6m', 'exclusive', 6, 24.49, NULL, 7),
    ('0x1_exclusive_12m', 'exclusive', 12, 32.99, NULL, 8)
), positions AS (
  SELECT COALESCE(MAX(position), 0) AS base_position FROM market.products
)
INSERT INTO market.products (
  sku, short_name, metadata, status, position, marketable,
  name, button_label
)
SELECT
  s.sku,
  '0x1 ' || initcap(s.tier) || ' Sub',
  jsonb_build_object(
    'family', '0x1_subscription',
    'tier', s.tier,
    'duration_months', s.duration_months,
    'payment_modes', CASE WHEN s.tier = 'special'
      THEN '["USDT", "SEED"]'::jsonb
      ELSE '["USDT"]'::jsonb
    END,
    'purchase', jsonb_build_object(
      'quantity_mode', 'single',
      'recipient', jsonb_build_object('provider', '0x1', 'modes', jsonb_build_array('self')),
      'fulfillment', 'not_configured'
    )
  ) || CASE WHEN s.seeds IS NOT NULL
      THEN jsonb_build_object('seed_price', jsonb_build_object(
        'currency', 'SEED', 'amount', s.seeds, 'symbol', '₴€£'
      ))
      ELSE '{}'::jsonb
    END,
  'inactive',
  positions.base_position + s.ordinal,
  true,
  '0x1 ' || initcap(s.tier) || ' Sub — ' || s.duration_months ||
    CASE WHEN s.duration_months = 1 THEN ' month' ELSE ' months' END,
  initcap(s.tier) || ' ' || s.duration_months || 'm'
FROM subscription_seed AS s
CROSS JOIN positions
ON CONFLICT (sku) DO NOTHING;

-- Provide en_US, uk_UA and ru_RU; remaining locales fall back to English.
-- Never replace an existing administrator localization.
WITH subscription_seed (sku, tier, duration_months) AS (
  VALUES
    ('0x1_special_1m', 'special', 1),
    ('0x1_special_3m', 'special', 3),
    ('0x1_special_6m', 'special', 6),
    ('0x1_special_12m', 'special', 12),
    ('0x1_exclusive_1m', 'exclusive', 1),
    ('0x1_exclusive_3m', 'exclusive', 3),
    ('0x1_exclusive_6m', 'exclusive', 6),
    ('0x1_exclusive_12m', 'exclusive', 12)
), locales (locale) AS (
  VALUES ('en_US'), ('uk_UA'), ('ru_RU')
)
INSERT INTO market.product_localizations (
  product_sku, locale, full_name, button_label
)
SELECT
  s.sku,
  l.locale,
  CASE l.locale
    WHEN 'uk_UA' THEN 'Підписка 0x1 ' || initcap(s.tier) || ' на ' ||
      s.duration_months || CASE WHEN s.duration_months = 1 THEN ' місяць'
        WHEN s.duration_months = 3 THEN ' місяці' ELSE ' місяців' END
    WHEN 'ru_RU' THEN 'Подписка 0x1 ' || initcap(s.tier) || ' на ' ||
      s.duration_months || CASE WHEN s.duration_months = 1 THEN ' месяц'
        WHEN s.duration_months = 3 THEN ' месяца' ELSE ' месяцев' END
    ELSE '0x1 ' || initcap(s.tier) || ' Sub — ' || s.duration_months ||
      CASE WHEN s.duration_months = 1 THEN ' month' ELSE ' months' END
  END,
  initcap(s.tier) || ' ' || s.duration_months || 'm'
FROM subscription_seed AS s
CROSS JOIN locales AS l
JOIN market.products AS p ON p.sku = s.sku
ON CONFLICT (product_sku, locale) DO NOTHING;

-- Only seed a first-ever USDT price. An existing administrative price is
-- authoritative; migrations must not overwrite live commercial decisions.
WITH introductory_prices (sku, amount_usdt) AS (
  VALUES
    ('0x1_special_1m', 2.49),
    ('0x1_special_3m', 6.29),
    ('0x1_special_6m', 11.49),
    ('0x1_special_12m', 14.99),
    ('0x1_exclusive_1m', 5.49),
    ('0x1_exclusive_3m', 13.99),
    ('0x1_exclusive_6m', 24.49),
    ('0x1_exclusive_12m', 32.99)
)
INSERT INTO market.product_prices (sku, amount_usdt, source)
SELECT s.sku, s.amount_usdt, 'core'
FROM introductory_prices AS s
JOIN market.products AS p ON p.sku = s.sku
WHERE NOT EXISTS (
  SELECT 1 FROM market.product_prices AS existing WHERE existing.sku = s.sku
);
