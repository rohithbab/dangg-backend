-- =============================================================================
-- USER_BLOCKS — bidirectional in effect, unidirectional in disclosure
--
-- If A blocks B:
--   * A no longer sees B in browse (via the CREATE OR REPLACE view below).
--   * B no longer sees A in browse (same filter, both directions).
--   * Neither side can send chat-requests to the other (Section C edit to
--     chat-requests-send).
--   * B does NOT know A blocked them — RLS on user_blocks only exposes
--     blocker's own rows. The chat-request error message is generic.
--
-- Schema notes:
--   * Both FKs CASCADE on user delete — when an account is deleted, all
--     blocks they authored disappear (and all blocks against them too).
--     The blocked column NEVER references payouts/coin-ledger style
--     constraints, so cascade is safe here.
--   * UNIQUE(blocker_id, blocked_id) + the no-self CHECK are the two
--     hard constraints; everything else is RLS / Edge-Function logic.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.user_blocks (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  blocker_id UUID NOT NULL REFERENCES public.users (id) ON DELETE CASCADE,
  blocked_id UUID NOT NULL REFERENCES public.users (id) ON DELETE CASCADE,
  reason TEXT CHECK (reason IS NULL OR char_length(reason) BETWEEN 1 AND 500),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  UNIQUE (blocker_id, blocked_id),
  CONSTRAINT user_blocks_no_self CHECK (blocker_id <> blocked_id)
);

COMMENT ON TABLE public.user_blocks IS
  'Per-(blocker,blocked) row. Effect is bidirectional (browse + chat-requests gate both ways); disclosure is unidirectional (only the blocker sees the row).';
COMMENT ON COLUMN public.user_blocks.reason IS
  'Optional reason text supplied by the blocker, 1..500 chars when present. Stored for the blocker''s own reference and for admin moderation tools.';

CREATE INDEX IF NOT EXISTS user_blocks_blocker_id_idx ON public.user_blocks (blocker_id);
CREATE INDEX IF NOT EXISTS user_blocks_blocked_id_idx ON public.user_blocks (blocked_id);

-- ---------------------------------------------------------------------------
-- RLS — blocker reads own rows. No other reader (the blocked user must NOT
-- know they were blocked). All writes via Edge Functions (service_role).
-- ---------------------------------------------------------------------------
ALTER TABLE public.user_blocks ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS user_blocks_select_own ON public.user_blocks;
CREATE POLICY user_blocks_select_own
  ON public.user_blocks
  FOR SELECT
  USING (auth.uid() = blocker_id);

COMMENT ON POLICY user_blocks_select_own ON public.user_blocks IS
  'Only the blocker sees their own block rows. The blocked user has NO read access — preserves the unidirectional-disclosure invariant.';

-- ---------------------------------------------------------------------------
-- CREATE OR REPLACE females_available_view — now caller-aware.
--
-- The view runs as SECURITY DEFINER (postgres role), so RLS on user_blocks
-- does NOT filter it from inside. We reference auth.uid() directly in the
-- WHERE clause — that returns the calling user's id when the view is read
-- through a user session, and NULL when read by service_role. With NULL the
-- two anti-block NOT EXISTS clauses are simply always TRUE, so service-role
-- reads see every browseable female (which is correct for admin tools).
-- ---------------------------------------------------------------------------
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
  AND f.verification_status = 'verified'
  -- Exclude females the caller has blocked.
  AND NOT EXISTS (
    SELECT 1 FROM public.user_blocks ub
     WHERE ub.blocker_id = auth.uid()
       AND ub.blocked_id = u.id
  )
  -- Exclude females who have blocked the caller.
  AND NOT EXISTS (
    SELECT 1 FROM public.user_blocks ub
     WHERE ub.blocker_id = u.id
       AND ub.blocked_id = auth.uid()
  );

GRANT SELECT ON public.females_available_view TO authenticated;

COMMENT ON VIEW public.females_available_view IS
  'Browse-safe view of verified, active, non-suspended females. Caller-aware: excludes females the caller blocked AND females who blocked the caller. Service-role reads (auth.uid() IS NULL) see all browseable females — intended for admin tools.';
