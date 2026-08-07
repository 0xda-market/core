CREATE UNIQUE INDEX broker_payouts_one_in_flight_per_seller_idx
  ON market.broker_payouts (seller_user_id)
  WHERE state IN ('queued', 'processing');

CREATE UNIQUE INDEX broker_payouts_network_reference_uidx
  ON market.broker_payouts (network, external_reference)
  WHERE external_reference IS NOT NULL;
