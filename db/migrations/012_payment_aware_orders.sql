ALTER TABLE market.orders
  ADD COLUMN payment jsonb;

DO $$
DECLARE
  constraint_record record;
BEGIN
  FOR constraint_record IN
    SELECT conname
    FROM pg_constraint
    WHERE conrelid = 'market.orders'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%status%'
  LOOP
    EXECUTE format(
      'ALTER TABLE market.orders DROP CONSTRAINT %I',
      constraint_record.conname
    );
  END LOOP;
END $$;

ALTER TABLE market.orders
  ADD CONSTRAINT orders_status_check
    CHECK (
      status IN (
        'payment_pending',
        'accepted',
        'processing',
        'pending',
        'succeeded',
        'failed',
        'cancelled'
      )
    );

ALTER TABLE market.listing_reservations
  DROP CONSTRAINT IF EXISTS listing_reservations_status_check;

ALTER TABLE market.listing_reservations
  ADD CONSTRAINT listing_reservations_status_check
    CHECK (status IN ('active', 'payment_pending', 'committed', 'released'));
