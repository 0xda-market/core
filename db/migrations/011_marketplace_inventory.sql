ALTER TABLE market.broker_listings
  ADD COLUMN available_quantity numeric(28, 12),
  ADD COLUMN reserved_quantity numeric(28, 12) NOT NULL DEFAULT 0,
  ADD COLUMN sold_quantity numeric(28, 12) NOT NULL DEFAULT 0;

UPDATE market.broker_listings
SET available_quantity = quantity
WHERE available_quantity IS NULL;

ALTER TABLE market.broker_listings
  ALTER COLUMN available_quantity SET NOT NULL,
  ADD CONSTRAINT broker_listings_available_quantity_check
    CHECK (available_quantity >= 0),
  ADD CONSTRAINT broker_listings_reserved_quantity_check
    CHECK (reserved_quantity >= 0),
  ADD CONSTRAINT broker_listings_sold_quantity_check
    CHECK (sold_quantity >= 0),
  ADD CONSTRAINT broker_listings_inventory_balance_check
    CHECK (quantity = available_quantity + reserved_quantity + sold_quantity);

CREATE TABLE market.listing_reservations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  listing_id uuid NOT NULL REFERENCES market.broker_listings(id),
  customer_user_id uuid NOT NULL REFERENCES market.users(id),
  quote_id text NOT NULL UNIQUE,
  order_id text UNIQUE,
  quantity numeric(28, 12) NOT NULL CHECK (quantity > 0),
  status text NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'committed', 'released')),
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  version bigint NOT NULL DEFAULT 0 CHECK (version >= 0)
);

CREATE INDEX listing_reservations_listing_status_expires_at_index
  ON market.listing_reservations(listing_id, status, expires_at);

CREATE INDEX listing_reservations_customer_created_at_index
  ON market.listing_reservations(customer_user_id, created_at DESC, id DESC);

CREATE INDEX broker_listings_liquidity_index
  ON market.broker_listings(sku, currency, price_amount, created_at, id)
  WHERE status = 'active' AND available_quantity > 0;

ALTER TABLE market.listing_reservations ENABLE ROW LEVEL SECURITY;
