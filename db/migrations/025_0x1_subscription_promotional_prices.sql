-- © 2026 aiaiaiai · aiaiaiai.org
-- SPDX-License-Identifier: MIT
--
-- Stage repriced 0x1 subscription terms. Percent discounts (0/15/35/50)
-- are applied to the monthly USDT anchor, then adjusted to the nearest
-- approved promotional ending (.29, .49, .69, .99). This is a pricing
-- decision, not the localized FX upward-only rounding algorithm.
--
-- Preserve migrations 020/022, issued quotes, and historical price rows.
-- Update only untouched system-seeded inactive catalog entries. In particular,
-- never overwrite an administrator price or enable a subscription sale.

WITH proposed(sku, old_usdt, new_usdt) AS (
  VALUES
    ('0x1_special_1m', 2.49, 2.49),
    ('0x1_special_3m', 6.29, 6.29),
    ('0x1_special_6m', 11.49, 9.69),
    ('0x1_special_12m', 14.99, 14.99),
    ('0x1_exclusive_1m', 5.49, 4.99),
    ('0x1_exclusive_3m', 13.99, 12.69),
    ('0x1_exclusive_6m', 24.49, 19.49),
    ('0x1_exclusive_12m', 32.99, 29.99)
)
INSERT INTO market.product_prices (sku, amount_usdt, source)
SELECT proposed.sku, proposed.new_usdt, 'core'
FROM proposed
JOIN market.products AS product ON product.sku = proposed.sku
CROSS JOIN LATERAL (
  SELECT amount_usdt, source
  FROM market.product_prices AS prior
  WHERE prior.sku = proposed.sku
  ORDER BY created_at DESC, id DESC
  LIMIT 1
) AS latest
WHERE product.status = 'inactive'
  AND product.metadata ->> 'family' = '0x1_subscription'
  AND latest.source = 'core'
  AND latest.amount_usdt = proposed.old_usdt
  AND latest.amount_usdt IS DISTINCT FROM proposed.new_usdt;

-- seeds have their own whole-unit ledger and NO FX or USDT equivalence.
-- Only Special supports this denomination; Exclusive remains USDT-only.
-- Preserve admins' denomination prices and the legacy catalog's provenance.
WITH proposed(sku, old_amount, new_amount) AS (
  VALUES
    ('0x1_special_1m', 400, 640),
    ('0x1_special_3m', 1020, 1632),
    ('0x1_special_6m', 1800, 2496),
    ('0x1_special_12m', 2400, 3840)
)
INSERT INTO market.denomination_prices
  (sku, denomination, amount_minor, source)
SELECT proposed.sku, 'seeds', proposed.new_amount, 'core'
FROM proposed
JOIN market.products AS product ON product.sku = proposed.sku
CROSS JOIN LATERAL (
  SELECT amount_minor, source
  FROM market.denomination_prices AS prior
  WHERE prior.sku = proposed.sku AND prior.denomination = 'seeds'
  ORDER BY id DESC
  LIMIT 1
) AS latest
WHERE product.status = 'inactive'
  AND product.metadata ->> 'family' = '0x1_subscription'
  AND product.metadata -> 'payment_modes' ? 'seeds'
  AND latest.source = 'core'
  AND latest.amount_minor = proposed.old_amount
  AND latest.amount_minor IS DISTINCT FROM proposed.new_amount;

-- Keep the staged preview metadata in sync only when still at the legacy
-- seed price. An administrator's independent metadata edits remain intact.
WITH proposed(sku, old_amount, new_amount) AS (
  VALUES
    ('0x1_special_1m', 400, 640),
    ('0x1_special_3m', 1020, 1632),
    ('0x1_special_6m', 1800, 2496),
    ('0x1_special_12m', 2400, 3840)
)
UPDATE market.products AS product
   SET metadata = jsonb_set(
         product.metadata, '{seed_price,amount}',
         to_jsonb(proposed.new_amount), false
       ),
       updated_at = now(),
       version = product.version + 1
  FROM proposed
 WHERE product.sku = proposed.sku
   AND product.status = 'inactive'
   AND product.metadata ->> 'family' = '0x1_subscription'
   AND product.metadata #>> '{seed_price,currency}' = 'seeds'
   AND product.metadata #>> '{seed_price,amount}' = proposed.old_amount::text
   AND EXISTS (
     SELECT 1
       FROM market.denomination_prices AS price
      WHERE price.sku = proposed.sku
        AND price.denomination = 'seeds'
        AND price.amount_minor = proposed.new_amount
        AND price.source = 'core'
        AND price.id = (
          SELECT MAX(newest.id)
            FROM market.denomination_prices AS newest
           WHERE newest.sku = proposed.sku
             AND newest.denomination = 'seeds'
        )
   );
