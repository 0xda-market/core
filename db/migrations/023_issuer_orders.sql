-- Issuer orders: purchases of eligible goods paid in an issuer denomination.
-- The issuer owns the balance, the debit and the entitlement grant. The market
-- records the customer's request with a snapshotted price and recipient, then
-- waits for the issuer's asynchronous decision. No balance, USDT valuation,
-- FX rate, broker inventory or market settlement is involved.

-- Lifecycle:
--   pending -> processing (issuer claimed it; the customer can no longer cancel)
--   pending -> cancelled  (customer, before any issuer claim)
--   pending | processing -> rejected (issuer, with a code)
--   processing -> fulfilled (issuer debited and granted, with a reference)
CREATE TABLE market.issuer_orders (
  id uuid PRIMARY KEY,
  customer_user_id uuid NOT NULL REFERENCES market.users(id),
  idempotency_key text NOT NULL
    CHECK (idempotency_key ~ '^[A-Za-z0-9._:-]{8,128}$'),
  sku text NOT NULL REFERENCES market.products(sku),
  denomination text NOT NULL REFERENCES market.denominations(code),
  issuer text NOT NULL,
  amount_minor bigint NOT NULL CHECK (amount_minor > 0),
  price_id bigint NOT NULL REFERENCES market.denomination_prices(id),
  -- The issuer account's public handle, as the issuer's directory answered
  -- when the order was created.
  recipient_subject text NOT NULL CHECK (length(recipient_subject) BETWEEN 1 AND 256),
  -- The channel account the issuer's directory resolved, so the issuer can
  -- re-check that binding before it debits.
  link_provider text NOT NULL,
  link_provider_user_id text NOT NULL,
  status text NOT NULL
    CHECK (status IN ('pending', 'processing', 'fulfilled', 'rejected', 'cancelled')),
  issuer_reference text CHECK (length(issuer_reference) BETWEEN 1 AND 256),
  rejection_code text CHECK (rejection_code ~ '^[a-z][a-z0-9_]{1,63}$'),
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  claimed_at timestamptz,
  completed_at timestamptz,
  version bigint NOT NULL DEFAULT 0 CHECK (version >= 0),
  UNIQUE (customer_user_id, idempotency_key),
  CHECK ((status = 'fulfilled') = (issuer_reference IS NOT NULL)),
  CHECK ((status = 'rejected') = (rejection_code IS NOT NULL)),
  CHECK ((status IN ('fulfilled', 'rejected', 'cancelled')) = (completed_at IS NOT NULL))
);

-- One issuer reference proves exactly one fulfilled order.
CREATE UNIQUE INDEX issuer_orders_issuer_reference_index
  ON market.issuer_orders(issuer, issuer_reference)
  WHERE issuer_reference IS NOT NULL;

CREATE INDEX issuer_orders_issuer_queue_index
  ON market.issuer_orders(issuer, status, created_at, id);

CREATE INDEX issuer_orders_customer_index
  ON market.issuer_orders(customer_user_id, created_at DESC);

-- Append-only audit of every observed transition and who caused it.
CREATE TABLE market.issuer_order_events (
  id bigserial PRIMARY KEY,
  order_id uuid NOT NULL REFERENCES market.issuer_orders(id),
  from_status text,
  to_status text NOT NULL,
  actor text NOT NULL CHECK (actor IN ('customer', 'issuer')),
  data jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL
);

CREATE INDEX issuer_order_events_order_index
  ON market.issuer_order_events(order_id, id);

CREATE FUNCTION market.reject_issuer_order_event_rewrite()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'issuer order events are append-only'
    USING ERRCODE = 'restrict_violation';
END;
$$;

CREATE TRIGGER issuer_order_events_append_only
BEFORE UPDATE OR DELETE ON market.issuer_order_events
FOR EACH ROW
EXECUTE FUNCTION market.reject_issuer_order_event_rewrite();
