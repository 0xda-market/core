-- Complete product copy for the primary language matrix. English remains the
-- canonical fallback; European skeleton locales intentionally use that fallback
-- until their own copy is promoted to full support.
INSERT INTO market.product_localizations (
  product_sku, locale, full_name, button_label, created_at, updated_at, version
)
VALUES
  ('premium_3m', 'ru_RU', 'Telegram Premium на 3 месяца', 'Premium 3 мес.', now(), now(), 0),
  ('premium_6m', 'ru_RU', 'Telegram Premium на 6 месяцев', 'Premium 6 мес.', now(), now(), 0),
  ('premium_12m', 'ru_RU', 'Telegram Premium на 12 месяцев', 'Premium 12 мес.', now(), now(), 0),
  ('stars_500', 'ru_RU', 'Telegram Stars 500', 'Stars 500', now(), now(), 0),
  ('stars_1000', 'ru_RU', 'Telegram Stars 1000', 'Stars 1000', now(), now(), 0),
  ('stars_3000', 'ru_RU', 'Telegram Stars 3000', 'Stars 3000', now(), now(), 0),
  ('ton', 'ru_RU', 'TON', 'TON', now(), now(), 0),
  ('btc', 'ru_RU', 'Bitcoin', 'BTC', now(), now(), 0),
  ('eth', 'ru_RU', 'Ethereum', 'ETH', now(), now(), 0),
  ('usdt', 'ru_RU', 'Tether USD', 'USDT', now(), now(), 0),
  ('usd', 'ru_RU', 'Доллар США', 'USD', now(), now(), 0),
  ('uah', 'ru_RU', 'Украинская гривна', 'UAH', now(), now(), 0),
  ('rub', 'ru_RU', 'Российский рубль', 'RUB', now(), now(), 0),
  ('eur', 'ru_RU', 'Евро', 'EUR', now(), now(), 0),
  ('gbp', 'ru_RU', 'Британский фунт', 'GBP', now(), now(), 0),
  ('chf', 'ru_RU', 'Швейцарский франк', 'CHF', now(), now(), 0),
  ('pln', 'ru_RU', 'Польский злотый', 'PLN', now(), now(), 0),
  ('czk', 'ru_RU', 'Чешская крона', 'CZK', now(), now(), 0),
  ('huf', 'ru_RU', 'Венгерский форинт', 'HUF', now(), now(), 0),

  ('premium_3m', 'es_ES', 'Telegram Premium por 3 meses', 'Premium 3 meses', now(), now(), 0),
  ('premium_6m', 'es_ES', 'Telegram Premium por 6 meses', 'Premium 6 meses', now(), now(), 0),
  ('premium_12m', 'es_ES', 'Telegram Premium por 12 meses', 'Premium 12 meses', now(), now(), 0),
  ('stars_500', 'es_ES', 'Telegram Stars 500', 'Stars 500', now(), now(), 0),
  ('stars_1000', 'es_ES', 'Telegram Stars 1000', 'Stars 1000', now(), now(), 0),
  ('stars_3000', 'es_ES', 'Telegram Stars 3000', 'Stars 3000', now(), now(), 0),
  ('ton', 'es_ES', 'TON', 'TON', now(), now(), 0),
  ('btc', 'es_ES', 'Bitcoin', 'BTC', now(), now(), 0),
  ('eth', 'es_ES', 'Ethereum', 'ETH', now(), now(), 0),
  ('usdt', 'es_ES', 'Tether USD', 'USDT', now(), now(), 0),
  ('usd', 'es_ES', 'Dólar estadounidense', 'USD', now(), now(), 0),
  ('uah', 'es_ES', 'Grivna ucraniana', 'UAH', now(), now(), 0),
  ('rub', 'es_ES', 'Rublo ruso', 'RUB', now(), now(), 0),
  ('eur', 'es_ES', 'Euro', 'EUR', now(), now(), 0),
  ('gbp', 'es_ES', 'Libra esterlina', 'GBP', now(), now(), 0),
  ('chf', 'es_ES', 'Franco suizo', 'CHF', now(), now(), 0),
  ('pln', 'es_ES', 'Esloti polaco', 'PLN', now(), now(), 0),
  ('czk', 'es_ES', 'Corona checa', 'CZK', now(), now(), 0),
  ('huf', 'es_ES', 'Forinto húngaro', 'HUF', now(), now(), 0),

  ('premium_3m', 'pt_BR', 'Telegram Premium por 3 meses', 'Premium 3 meses', now(), now(), 0),
  ('premium_6m', 'pt_BR', 'Telegram Premium por 6 meses', 'Premium 6 meses', now(), now(), 0),
  ('premium_12m', 'pt_BR', 'Telegram Premium por 12 meses', 'Premium 12 meses', now(), now(), 0),
  ('stars_500', 'pt_BR', 'Telegram Stars 500', 'Stars 500', now(), now(), 0),
  ('stars_1000', 'pt_BR', 'Telegram Stars 1000', 'Stars 1000', now(), now(), 0),
  ('stars_3000', 'pt_BR', 'Telegram Stars 3000', 'Stars 3000', now(), now(), 0),
  ('ton', 'pt_BR', 'TON', 'TON', now(), now(), 0),
  ('btc', 'pt_BR', 'Bitcoin', 'BTC', now(), now(), 0),
  ('eth', 'pt_BR', 'Ethereum', 'ETH', now(), now(), 0),
  ('usdt', 'pt_BR', 'Tether USD', 'USDT', now(), now(), 0),
  ('usd', 'pt_BR', 'Dólar americano', 'USD', now(), now(), 0),
  ('uah', 'pt_BR', 'Hryvnia ucraniana', 'UAH', now(), now(), 0),
  ('rub', 'pt_BR', 'Rublo russo', 'RUB', now(), now(), 0),
  ('eur', 'pt_BR', 'Euro', 'EUR', now(), now(), 0),
  ('gbp', 'pt_BR', 'Libra esterlina', 'GBP', now(), now(), 0),
  ('chf', 'pt_BR', 'Franco suíço', 'CHF', now(), now(), 0),
  ('pln', 'pt_BR', 'Zlóti polonês', 'PLN', now(), now(), 0),
  ('czk', 'pt_BR', 'Coroa tcheca', 'CZK', now(), now(), 0),
  ('huf', 'pt_BR', 'Florim húngaro', 'HUF', now(), now(), 0);

-- Currency geography is an independent presentation hint. These mappings are
-- deliberately regional: language-only aliases must not silently imply a
-- country or currency.
UPDATE market.products
SET metadata = jsonb_set(
  metadata,
  '{locales}',
  CASE sku
    WHEN 'usd' THEN '["en_US"]'::jsonb
    WHEN 'uah' THEN '["uk_UA"]'::jsonb
    WHEN 'rub' THEN '["ru_RU"]'::jsonb
    WHEN 'eur' THEN '["de_DE","fr_FR","it_IT","es_ES"]'::jsonb
    WHEN 'gbp' THEN '["en_GB"]'::jsonb
    WHEN 'chf' THEN '["de_CH","fr_CH","it_CH"]'::jsonb
    WHEN 'pln' THEN '["pl_PL"]'::jsonb
    WHEN 'czk' THEN '["cs_CZ"]'::jsonb
    WHEN 'huf' THEN '["hu_HU"]'::jsonb
    ELSE '[]'::jsonb
  END,
  true
)
WHERE sku IN ('usd', 'uah', 'rub', 'eur', 'gbp', 'chf', 'pln', 'czk', 'huf');
