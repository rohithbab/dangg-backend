-- =============================================================================
-- HELPER: current_user_role()
--
-- Returns the role of the calling user, read from public.users.
--
-- STABLE + SECURITY DEFINER:
--   * STABLE lets Postgres cache the result within a single query, so RLS
--     policies that call this once per row don't repeatedly hit users.
--   * SECURITY DEFINER bypasses RLS for the internal lookup — necessary
--     because some RLS policies that call this would otherwise recurse
--     (the policy reads users to decide who can read users).
--
-- Pinned `search_path` neutralises the standard SECURITY DEFINER hijack
-- vector where a caller could shadow `public.users` with their own schema.
--
-- Reusable across every future RLS policy that needs to gate on role.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.current_user_role()
RETURNS user_role
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT role FROM public.users WHERE id = auth.uid();
$$;

COMMENT ON FUNCTION public.current_user_role() IS
  'Returns the role of the calling user from public.users. STABLE + SECURITY DEFINER for cheap calls from RLS policies. Reuse, never inline a subquery.';

GRANT EXECUTE ON FUNCTION public.current_user_role() TO authenticated;
