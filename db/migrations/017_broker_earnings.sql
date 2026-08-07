CREATE TABLE market.broker_earnings (
  id uuid PRIMARY KEY,
  order_id text NOT NULL UNIQUE REFERENCES market.orders(id),
  reservation_id uuid NOT NULL UNIQUE REFERENCES market.listing_reservations(id),
  listing_id uuid NOT NULL REFERENCES market.listings(id),
  seller_user_id uuid NOT NULL REFERENCES market.users(id),
  quantity numeric(28, 12) NOT NULL CHECK (quantity > 0),
  ask_amount numeric(28, 8) NOT NULL CHECK (ask_amount > 0),
  ask_currency text NOT NULL,
  payable_amount numeric(30, 12) NOT NULL CHECK (payable_amount > 0),
  payable_currency text NOT NULL,
  state text NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'available', 'payout_queued', 'paid', 'void')),
  payout_id uuid,
  available_at timestamptz,
  paid_at timestamptz,
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  version integer NOT NULL DEFAULT 0 CHECK (version >= 0)
);

CREATE INDEX broker_earnings_seller_state_idx
  ON market.broker_earnings (seller_user_id, state, updated_at DESC);

CREATE TABLE market.broker_payout_profiles (
  seller_user_id uuid PRIMARY KEY REFERENCES market.users(id),
  currency text NOT NULL DEFAULT 'USDT',
  network text NOT NULL,
  destination text NOT NULL,
  minimum_payout_amount numeric(30, 12) NOT NULL DEFAULT 0 CHECK (minimum_payout_amount >= 0),
  enabled boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  version integer NOT NULL DEFAULT 0 CHECK (version >= 0)
);

CREATE TABLE market.broker_payouts (
  id uuid PRIMARY KEY,
  seller_user_id uuid NOT NULL REFERENCES market.users(id),
  currency text NOT NULL,
  network text NOT NULL,
  destination text NOT NULL,
  amount numeric(30, 12) NOT NULL CHECK (amount > 0),
  state text NOT NULL DEFAULT 'queued' CHECK (state IN ('queued', 'processing', 'paid', 'failed')),
  idempotency_key text NOT NULL UNIQUE,
  external_reference text,
  provider_data jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  paid_at timestamptz,
  version integer NOT NULL DEFAULT 0 CHECK (version >= 0)
);

CREATE INDEX broker_payouts_seller_state_idx
  ON market.broker_payouts (seller_user_id, state, updated_at DESC);

ALTER TABLE market.broker_earnings
  ADD CONSTRAINT broker_earnings_payout_fk
  FOREIGN KEY (payout_id) REFERENCES market.broker_payouts(id);
