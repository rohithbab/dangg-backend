-- =============================================================================
-- STATS PERFORMANCE INDEXES
--
-- The stats Edge Functions (stats-female / stats-male) run several count +
-- sum queries grouped by user_id × status / type. Most of these are already
-- served by indexes from prior migrations (chat_requests_*_created_at_idx,
-- coin_transactions_male_id_created_at_idx, etc.); the indexes added here
-- close two specific gaps:
--
--   1. Status-filtered grouping per user — the existing indexes are sorted
--      by created_at, which is great for "recent activity" but does extra
--      filtering work for "count by status". A (user_id, status) index
--      cuts that to a single index seek per status bucket.
--
--   2. Coin / earnings ledger filters by `type` — the prior indexes are
--      (user_id, created_at) and (type) separately. A composite
--      (user_id, type) collapses the sum-by-type query into one bitmap.
--
-- All idempotent (IF NOT EXISTS) — safe to re-run.
-- =============================================================================

CREATE INDEX IF NOT EXISTS chat_requests_male_status_idx
  ON public.chat_requests (male_id, status);

CREATE INDEX IF NOT EXISTS chat_requests_female_status_idx
  ON public.chat_requests (female_id, status);

CREATE INDEX IF NOT EXISTS coin_transactions_male_type_idx
  ON public.coin_transactions (male_id, type);

CREATE INDEX IF NOT EXISTS female_earnings_female_type_idx
  ON public.female_earnings (female_id, type);

COMMENT ON INDEX public.chat_requests_male_status_idx   IS 'stats-male: count by status per male.';
COMMENT ON INDEX public.chat_requests_female_status_idx IS 'stats-female: count by status per female.';
COMMENT ON INDEX public.coin_transactions_male_type_idx IS 'stats-male: sum chat_charge / chat_refund per male.';
COMMENT ON INDEX public.female_earnings_female_type_idx IS 'stats-female: sum chat_earning per female across time windows.';
