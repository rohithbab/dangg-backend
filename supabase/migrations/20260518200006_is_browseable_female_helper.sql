-- =============================================================================
-- HELPER: is_browseable_female(uuid)
--
-- Returns TRUE when the given user id is a verified, active, non-suspended
-- female — i.e., they would appear in `females_available_view`.
--
-- WHY THIS EXISTS
--   Several RLS policies (favorites, chat_requests when it lands, ratings,
--   blocks, etc.) need to verify "is the OTHER user a real, browseable
--   female?" inside a WITH CHECK clause. Without help, that EXISTS check
--   runs in the calling user's RLS context and the male can't see the
--   female's row, so the check always fails.
--
--   SECURITY DEFINER lets this helper bypass RLS on users / females for
--   the lookup, returning a clean boolean to the policy. Pinned
--   `search_path` defuses the standard SECURITY DEFINER hijack vector.
--
-- The corresponding `is_browseable_male()` will land alongside the
-- chat-request migration where it's first needed.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.is_browseable_female(p_user_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.users u
    JOIN public.females f ON f.id = u.id
    WHERE u.id = p_user_id
      AND u.role = 'female'
      AND u.is_active = TRUE
      AND u.is_suspended = FALSE
      AND f.verification_status = 'verified'
  );
$$;

COMMENT ON FUNCTION public.is_browseable_female(UUID) IS
  'Returns TRUE if the given user is a verified, active, non-suspended female. Bypasses RLS so it can be called safely from RLS WITH CHECK clauses on other tables.';

GRANT EXECUTE ON FUNCTION public.is_browseable_female(UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- Replace favorites_insert_own policy so it calls the helper instead of
-- inlining the RLS-blocked EXISTS subquery. Also drop the redundant
-- male_id <> female_id check — the `favorites_no_self` CHECK constraint
-- on the table is the authoritative enforcer for that.
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS favorites_insert_own ON public.favorites;

CREATE POLICY favorites_insert_own
  ON public.favorites
  FOR INSERT
  WITH CHECK (
    auth.uid() = male_id
    AND public.current_user_role() = 'male'
    AND public.is_browseable_female(female_id)
  );

COMMENT ON POLICY favorites_insert_own ON public.favorites IS
  'Insert gated to the calling male, role=male, and a verified active female target via is_browseable_female(). Self-favorite is blocked by the favorites_no_self CHECK constraint.';
