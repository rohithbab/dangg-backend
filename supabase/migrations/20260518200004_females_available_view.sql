-- =============================================================================
-- FEMALES_AVAILABLE_VIEW
--
-- Browse-safe public-facing view used by males to discover females and to
-- render the Female Profile Preview screen.
--
-- SECURITY MODEL
--   * Default Postgres views are SECURITY DEFINER — they run with the
--     definer's privileges (here: postgres). RLS on the underlying tables
--     is NOT applied when querying through the view; the view's WHERE
--     clause IS the security filter.
--   * The SELECT clause is an EXPLICIT ALLOWLIST of columns. Sensitive
--     fields never appear here:
--       - payout_details (separate table, RLS-locked)
--       - verification photo paths (TBD; in Storage with its own bucket RLS)
--       - admin-only flags (verification_rejection_reason, decided_at, etc.)
--       - heartbeat / internal stats (last_heartbeat_at, total_ratings)
--   * Access is granted to the `authenticated` role only — never `anon` or
--     `public`.
--
-- ADDING NEW COLUMNS
--   If a sensitive column is added to `users` or `females` later, it does
--   NOT automatically leak through this view — it has to be explicitly
--   added to the SELECT list. That's the whole point of the allowlist.
-- =============================================================================

CREATE OR REPLACE VIEW public.females_available_view AS
SELECT
  u.id                              AS female_id,
  u.name,
  u.age,
  u.profile_picture_url,
  f.is_online,
  f.last_online_at,
  f.coin_price,
  f.rating_avg,
  f.total_chats,
  f.average_response_minutes,
  f.bio
FROM public.users u
INNER JOIN public.females f ON f.id = u.id
WHERE u.is_active = TRUE
  AND u.is_suspended = FALSE
  AND u.deletion_requested_at IS NULL
  AND f.verification_status = 'verified';

GRANT SELECT ON public.females_available_view TO authenticated;

COMMENT ON VIEW public.females_available_view IS
  'Browse-safe view of verified, active, non-suspended females. Explicit column allowlist — sensitive fields never appear. Read-only, authenticated role only.';
