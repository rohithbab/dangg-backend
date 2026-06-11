-- =============================================================================
-- Migration: Update users SELECT policy to support cross-user lookup in chat requests
--
-- Drops the restrictive `users_select_own` policy and replaces it with
-- `users_select_related` which permits selecting own row or any user row
-- that is linked to the active user via a chat request.
--
-- CRITICAL: outer users.id is qualified to prevent shadowing by chat_requests.id.
-- =============================================================================

DROP POLICY IF EXISTS users_select_own ON public.users;
DROP POLICY IF EXISTS users_select_related ON public.users;

CREATE POLICY users_select_related ON public.users
  FOR SELECT
  TO authenticated
  USING (
    auth.uid() = id
    OR EXISTS (
      SELECT 1 FROM public.chat_requests cr
      WHERE (cr.male_id = auth.uid() AND cr.female_id = public.users.id)
         OR (cr.female_id = auth.uid() AND cr.male_id = public.users.id)
    )
  );

COMMENT ON POLICY users_select_related ON public.users IS
  'Authenticated users see their own profile or profiles of users they have an active/pending chat request with.';
