-- =============================================================================
-- Migration: Browse-presence RLS for males + realtime delivery of availability
--
-- PROBLEM
--   Male Home subscribes to Realtime `postgres_changes` on `public.females`
--   to live-update the browse grid when a female toggles availability. But the
--   only SELECT policy on `females` was `females_select_own` (auth.uid() = id).
--   Realtime enforces the subscriber's RLS per row, so a male received NO
--   events when a female flipped `is_online` — the grid never updated live.
--
-- FIX
--   1. Add a permissive SELECT policy letting any authenticated user read
--      browseable (verified + active + non-suspended) females. It delegates to
--      the SECURITY DEFINER helper `is_browseable_female()` — an inline EXISTS
--      on `public.users` would run in the male's RLS context (users_select_related)
--      and return false for an unrelated female, denying the row. The helper
--      bypasses RLS for the lookup. It exposes nothing the browse view doesn't
--      already expose; `verification_rejection_reason` is always NULL for
--      verified rows, so no private data leaks. With this, a male can SELECT a
--      verified female's row and Realtime delivers her INSERT/UPDATE/DELETE
--      events to the male client.
--
--   2. Set REPLICA IDENTITY FULL on `females` so Realtime can evaluate RLS
--      against BOTH the old and new tuple of an UPDATE. This guarantees the
--      male receives the "went offline" / "verification revoked" transitions
--      (where the new row may no longer pass the policy) as leave events.
--
-- The existing `females_select_own` policy is kept — it's permissive, so the
-- two OR together: a female still sees her own (possibly unverified) row, and
-- everyone sees verified, browseable females.
-- =============================================================================

CREATE POLICY females_select_browseable
  ON public.females
  FOR SELECT
  TO authenticated
  USING (
    verification_status = 'verified'
    AND public.is_browseable_female(public.females.id)
  );

COMMENT ON POLICY females_select_browseable ON public.females IS
  'Authenticated users may read verified, active, non-suspended females. Mirrors females_available_view filter — enables direct browse reads AND Realtime presence delivery to males.';

-- Realtime needs the full row to evaluate RLS on the OLD tuple of an UPDATE
-- (e.g. female going offline or losing verification). Default replica identity
-- only ships the primary key for the old tuple.
ALTER TABLE public.females REPLICA IDENTITY FULL;
