-- Normalize the 0x1 in-game currency to its lowercase public identifier:
-- "seeds". Migration 020 is immutable because it may already be applied.
-- This is NOT the market's fiat currency catalog; USDT remains uppercase.
-- ₴€£ is a visual currency symbol and has no letter case.
--
-- Preserve product prices, seed amounts, localized names and buyer status.
-- Only normalize the legacy initial Special metadata when the old identifiers
-- are present; do not overwrite independently edited commercial values.
UPDATE market.products
   SET metadata = jsonb_set(
     jsonb_set(
       metadata, '{payment_modes}', '["USDT", "seeds"]'::jsonb, false
     ),
     '{seed_price,currency}', '"seeds"'::jsonb, false
   ),
       updated_at = now(),
       version = version + 1
 WHERE sku IN (
   '0x1_special_1m', '0x1_special_3m',
   '0x1_special_6m', '0x1_special_12m'
 )
   AND metadata ->> 'family' = '0x1_subscription'
   AND metadata -> 'payment_modes' = '["USDT", "SEED"]'::jsonb
   AND metadata #>> '{seed_price,currency}' = 'SEED';
