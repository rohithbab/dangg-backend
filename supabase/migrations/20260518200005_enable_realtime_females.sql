-- =============================================================================
-- REALTIME: females table
--
-- Adds `public.females` to Supabase's default Realtime publication so
-- mobile clients can subscribe to row-level changes (online status,
-- last_online_at, coin_price, etc.) and update the browse UI in
-- real time without polling.
--
-- The mobile app subscribes with a filter — typically
-- `verification_status=eq.verified` — so only browse-visible females
-- generate events for that client.
--
-- PRIVACY NOTE
--   Realtime broadcasts the FULL row payload to subscribers, not a
--   view-filtered subset. The `females` table intentionally holds no
--   sensitive data — payout details live in `payout_details`, and the
--   verification photo path will live in Storage when that migration
--   lands. If a sensitive column is ever added to `females`, swap this
--   to FOR INSERT, UPDATE OF (allowed_columns) instead of broadcasting
--   the full row.
-- =============================================================================

ALTER PUBLICATION supabase_realtime ADD TABLE public.females;

COMMENT ON PUBLICATION supabase_realtime IS
  'Default Supabase Realtime publication. Includes public.females for browse-presence broadcasts.';
