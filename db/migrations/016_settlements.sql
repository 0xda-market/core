CREATE TABLE market.settlements (
  id text PRIMARY KEY,
  order_id text NOT NULL REFERENCES market.orders(id),
  provider_key text NOT NULL,
  state text NOT NULL CHECK (state IN ('pending', 'settled', 'failed', 'expired')),
  expected_usdt numeric(30, 12) NOT NULL CHECK (expected_usdt > 0),
  received_usdt numeric(30, 12) CHECK (received_usdt >= 0),
  currency text NOT NULL,
  tolerance_bps integer NOT NULL CHECK (tolerance_bps BETWEEN 0 AND 9999),
  idempotency_key text NOT NULL UNIQUE,
  external_reference text,
  provider_data jsonb NOT NULL DEFAULT '{}'::jsonb,
  expires_at timestamptz,
  lock_version integer NOT NULL DEFAULT 0 CHECK (lock_version >= 0),
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL
);

CREATE UNIQUE INDEX settlements_one_effective_per_order_idx
  ON market.settlements(order_id)
  WHERE state <> 'failed';

CREATE INDEX settlements_state_expires_at_idx
  ON market.settlements(state, expires_at);

CREATE TABLE market.settlement_events (
  id bigserial PRIMARY KEY,
  settlement_id text NOT NULL REFERENCES market.settlements(id),
  state text NOT NULL CHECK (state IN ('pending', 'settled', 'failed', 'expired')),
  provider_data jsonb NOT NULL DEFAULT '{}'::jsonb,
  observed_at timestamptz NOT NULL
);

CREATE INDEX settlement_events_settlement_observed_idx
  ON market.settlement_events(settlement_id, observed_at, id);
