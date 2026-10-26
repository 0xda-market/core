-- © 2026 aiaiaiai · aiaiaiai.org
-- SPDX-License-Identifier: MIT
--
-- Identify the issuer-backed system broker for 0x1 digital subscription
-- SKUs. This is a catalog supplier identity, NOT market.users, a human
-- broker, broker inventory, liquidity, or an entitlement/fulfillment grant.
--
-- Only annotate untouched, issuer-bound inactive records. Do not alter
-- legacy price history, create a user, activate a product, or mint inventory.
UPDATE market.products AS product
   SET metadata = jsonb_set(
         product.metadata,
         '{supplier}',
         '{"kind":"system_broker","id":"0x1","issuer":"0x1"}'::jsonb,
         true
       ),
       updated_at = now(),
       version = product.version + 1
 WHERE product.sku IN (
         '0x1_special_1m', '0x1_special_3m',
         '0x1_special_6m', '0x1_special_12m',
         '0x1_exclusive_1m', '0x1_exclusive_3m',
         '0x1_exclusive_6m', '0x1_exclusive_12m'
       )
   AND product.status = 'inactive'
   AND product.metadata ->> 'family' = '0x1_subscription'
   AND product.metadata #>> '{purchase,recipient,provider}' = '0x1'
   AND NOT (product.metadata ? 'supplier');
