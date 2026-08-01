CREATE TABLE market.broker_listings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  seller_user_id uuid NOT NULL REFERENCES market.users(id),
  sku text NOT NULL REFERENCES market.products(sku),
  quantity numeric(28, 12) NOT NULL CHECK (quantity > 0),
  price_amount numeric(28, 8) NOT NULL CHECK (price_amount > 0),
  currency text NOT NULL CHECK (currency ~ '^[A-Z][A-Z0-9]{2,9}$'),
  status text NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'withdrawn')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  version bigint NOT NULL DEFAULT 0 CHECK (version >= 0)
);

CREATE INDEX broker_listings_seller_status_updated_at_index
  ON market.broker_listings(seller_user_id, status, updated_at DESC, id DESC);

CREATE INDEX broker_listings_sku_status_updated_at_index
  ON market.broker_listings(sku, status, updated_at DESC, id DESC);

CREATE UNIQUE INDEX broker_listings_active_seller_asset_currency_index
  ON market.broker_listings(seller_user_id, sku, currency)
  WHERE status = 'active';

ALTER TABLE market.broker_listings ENABLE ROW LEVEL SECURITY;
