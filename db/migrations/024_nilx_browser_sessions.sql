-- © 2026 aiaiaiai · aiaiaiai.org
-- SPDX-License-Identifier: MIT
CREATE TABLE market.nilx_browser_sessions (
  digest TEXT PRIMARY KEY CHECK (length(digest) = 64),
  kind TEXT NOT NULL CHECK (kind IN ('handoff', 'session')),
  context JSONB NOT NULL,
  expires_at BIGINT NOT NULL
);
CREATE INDEX nilx_browser_sessions_expiry ON market.nilx_browser_sessions (expires_at);
