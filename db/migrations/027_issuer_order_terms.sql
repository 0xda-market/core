-- © 2026 aiaiaiai · aiaiaiai.org
-- SPDX-License-Identifier: MIT
--
-- Freeze what an issuer order buys and how long its confirmation authorizes
-- a debit. A subscription order snapshots its term from the catalog: N months
-- under `calendar_months_utc`, i.e. the same day of the month and time of day,
-- in UTC, N calendar months later (a missing day becomes the month's last day).
-- A browser-confirmed order also carries the deadline before which the issuer
-- may claim it; an expired, unclaimed order is rejected, never debited.
-- Existing rows keep NULL: they bought no subscription term and had no deadline.
ALTER TABLE market.issuer_orders
  ADD COLUMN term_months integer CHECK (term_months BETWEEN 1 AND 120),
  ADD COLUMN term_policy text CHECK (term_policy = 'calendar_months_utc'),
  ADD COLUMN authorization_expires_at timestamptz,
  ADD CONSTRAINT issuer_orders_term_complete
    CHECK ((term_months IS NULL) = (term_policy IS NULL)),
  ADD CONSTRAINT issuer_orders_authorization_after_creation
    CHECK (authorization_expires_at IS NULL OR authorization_expires_at > created_at);
