-- Issuer-owned denominations: non-fiat units of account (for example a game
-- currency) that an external issuer owns. The market stores only their
-- presentation contract and an append-only price history in that unit.
--
-- A denomination is NOT a fiat currency row: it never enters
-- market.product_prices, FX snapshots, USDT valuation, or client currency
-- conversion. Balances, debits and credits remain owned by the issuer and are
-- not stored here.
CREATE TABLE market.denominations (
  code text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]{1,31}$'),
  symbol text NOT NULL CHECK (length(symbol) BETWEEN 1 AND 16),
  scale smallint NOT NULL CHECK (scale BETWEEN 0 AND 6),
  issuer text NOT NULL CHECK (issuer ~ '^[a-z0-9][a-z0-9._-]{0,63}$'),
  status text NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'inactive')),
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Product families whose goods the issuer accepts its denomination for.
-- Goods outside these families can never be priced in the denomination.
CREATE TABLE market.denomination_product_families (
  denomination text NOT NULL REFERENCES market.denominations(code),
  family text NOT NULL CHECK (family ~ '^[a-z0-9][a-z0-9_]{0,63}$'),
  PRIMARY KEY (denomination, family)
);

-- amount_minor is an integer count of the denomination's smallest unit
-- (10^-scale). The current price is the last appended row (highest id) per
-- (sku, denomination); timestamps are descriptive, not an ordering key.
CREATE TABLE market.denomination_prices (
  id bigserial PRIMARY KEY,
  sku text NOT NULL REFERENCES market.products(sku),
  denomination text NOT NULL REFERENCES market.denominations(code),
  amount_minor bigint NOT NULL
    CHECK (amount_minor > 0 AND amount_minor <= 1000000000000),
  source text NOT NULL CHECK (source IN ('admin', 'core')),
  set_by_user_id uuid REFERENCES market.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX denomination_prices_current_index
  ON market.denomination_prices(denomination, sku, id DESC);

-- A price row is accepted only for a marketable product whose family is
-- eligible for the denomination and whose metadata.payment_modes declares it.
CREATE FUNCTION market.check_denomination_price_eligibility()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
      FROM market.products AS p
      JOIN market.denomination_product_families AS f
        ON f.denomination = NEW.denomination
       AND f.family = p.metadata ->> 'family'
     WHERE p.sku = NEW.sku
       AND p.marketable
       AND jsonb_typeof(p.metadata -> 'payment_modes') = 'array'
       AND p.metadata -> 'payment_modes' ? NEW.denomination
  ) THEN
    RAISE EXCEPTION 'product % is not eligible for denomination %',
      NEW.sku, NEW.denomination
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER denomination_prices_check_eligibility
BEFORE INSERT ON market.denomination_prices
FOR EACH ROW
EXECUTE FUNCTION market.check_denomination_price_eligibility();

-- The only permitted change is ON DELETE SET NULL of the editing user; the
-- price itself is never rewritten or removed.
CREATE FUNCTION market.reject_denomination_price_rewrite()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'UPDATE'
     AND NEW.set_by_user_id IS NULL
     AND (NEW.id, NEW.sku, NEW.denomination, NEW.amount_minor, NEW.source, NEW.created_at)
         IS NOT DISTINCT FROM
         (OLD.id, OLD.sku, OLD.denomination, OLD.amount_minor, OLD.source, OLD.created_at) THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'denomination price history is append-only'
    USING ERRCODE = 'restrict_violation';
END;
$$;

CREATE TRIGGER denomination_prices_append_only
BEFORE UPDATE OR DELETE ON market.denomination_prices
FOR EACH ROW
EXECUTE FUNCTION market.reject_denomination_price_rewrite();

-- seeds (display symbol ₴€£) is 0x1's in-game currency: one whole-unit
-- denomination, not UAH/EUR/GBP. It is accepted only for 0x1 game goods.
INSERT INTO market.denominations (code, symbol, scale, issuer, status)
VALUES ('seeds', '₴€£', 0, '0x1', 'active');

INSERT INTO market.denomination_product_families (denomination, family)
VALUES ('seeds', '0x1_subscription');

-- Carry the staged seed prices from catalog metadata into the price history.
-- Metadata is read, not modified; a product without a whole positive amount,
-- or one the eligibility trigger would reject, is skipped rather than guessed
-- so a drifted catalog cannot abort the migration.
INSERT INTO market.denomination_prices (sku, denomination, amount_minor, source)
SELECT p.sku, 'seeds', (p.metadata #>> '{seed_price,amount}')::bigint, 'core'
  FROM market.products AS p
  JOIN market.denomination_product_families AS f
    ON f.denomination = 'seeds'
   AND f.family = p.metadata ->> 'family'
 WHERE p.marketable
   AND p.metadata #>> '{seed_price,currency}' = 'seeds'
   AND jsonb_typeof(p.metadata #> '{seed_price,amount}') = 'number'
   AND (p.metadata #>> '{seed_price,amount}') ~ '^[1-9][0-9]{0,11}$'
   AND jsonb_typeof(p.metadata -> 'payment_modes') = 'array'
   AND p.metadata -> 'payment_modes' ? 'seeds'
   AND NOT EXISTS (
     SELECT 1
       FROM market.denomination_prices AS existing
      WHERE existing.sku = p.sku
        AND existing.denomination = 'seeds'
   )
 ORDER BY p.position, p.sku;
