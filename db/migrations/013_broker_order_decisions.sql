CREATE TABLE market.broker_order_decisions (
  order_id uuid PRIMARY KEY REFERENCES market.orders(id) ON DELETE CASCADE,
  reservation_id uuid NOT NULL UNIQUE REFERENCES market.listing_reservations(id) ON DELETE CASCADE,
  seller_user_id uuid NOT NULL REFERENCES market.users(id),
  status text NOT NULL DEFAULT 'requested',
  accepted_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  version integer NOT NULL DEFAULT 0,
  CONSTRAINT broker_order_decisions_status_check
    CHECK (status IN ('requested', 'accepted', 'completed')),
  CONSTRAINT broker_order_decisions_timestamps_check
    CHECK (
      (status = 'requested' AND accepted_at IS NULL AND completed_at IS NULL) OR
      (status = 'accepted' AND accepted_at IS NOT NULL AND completed_at IS NULL) OR
      (status = 'completed' AND accepted_at IS NOT NULL AND completed_at IS NOT NULL)
    )
);

CREATE INDEX broker_order_decisions_seller_status_idx
  ON market.broker_order_decisions (seller_user_id, status, updated_at DESC);
