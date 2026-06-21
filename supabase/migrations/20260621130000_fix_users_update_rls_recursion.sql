-- =============================================================================
-- Fix: "infinite recursion detected in policy for relation users"
--
-- The `users_update_own` policy's WITH CHECK compared the NEW role/phone to the
-- stored values using inline subqueries on `public.users`:
--     role  = (SELECT role  FROM users WHERE id = auth.uid())
--     phone = (SELECT phone FROM users WHERE id = auth.uid())
-- Those subqueries re-trigger RLS on `users`, which Postgres rejects as
-- infinite recursion — so EVERY authenticated self-update (incl. saving
-- `profile_picture_url`) failed. We keep the role/phone-immutability guarantee
-- but read the current values through SECURITY DEFINER helpers (which bypass
-- RLS, so there is no recursion).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.current_user_phone()
  RETURNS text
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO 'public'
AS $$
  SELECT phone FROM public.users WHERE id = auth.uid();
$$;

DROP POLICY IF EXISTS "users_update_own" ON public.users;
CREATE POLICY "users_update_own"
  ON public.users FOR UPDATE
  USING (auth.uid() = id)
  WITH CHECK (
    auth.uid() = id
    AND role = public.current_user_role()
    AND phone = public.current_user_phone()
  );
