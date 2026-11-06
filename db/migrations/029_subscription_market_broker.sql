-- © 2026 aiaiaiai · aiaiaiai.org
-- SPDX-License-Identifier: MIT

-- Brokerage and issuance are independent. A customer buys one term per
-- order from Market. The issuer grants it without reserving broker stock.
UPDATE market.products
SET metadata = jsonb_set(metadata, '{broker}',
      '{"kind":"market_broker","id":"0xda-market","stock":"unlimited"}'::jsonb),
    version = version + 1, updated_at = now()
WHERE sku IN ('0x1_special_1m', '0x1_special_3m', '0x1_special_6m', '0x1_special_12m',
              '0x1_exclusive_1m', '0x1_exclusive_3m', '0x1_exclusive_6m', '0x1_exclusive_12m')
  AND metadata->>'family' = '0x1_subscription'
  AND metadata->'supplier' = '{"kind":"system_broker","id":"0x1","issuer":"0x1"}'::jsonb
  AND metadata #>> '{purchase,quantity_mode}' = 'single'
  AND NOT (metadata ? 'broker');
