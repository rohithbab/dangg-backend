-- =============================================================================
-- handle_new_user — tolerate role='admin' in auth metadata
--
-- The init trigger casts raw_user_meta_data.role to the public.user_role
-- enum, which is end-user-only ('female', 'male'). Admin auth was always
-- meant to be a separate surface (per the init migration's comment), but
-- there was no way to actually CREATE an admin auth.users row — the cast
-- failed and the whole signup aborted.
--
-- This migration replaces the trigger so:
--   * role = 'female' / 'male' → unchanged: cast + mirror into public.users.
--   * role = 'admin'           → auth.users row is created, NOTHING is
--                                inserted into public.users. Admins live
--                                entirely off-DB; is_admin() reads the JWT.
--   * role missing / unknown   → still raises with the same hint as before.
--
-- This unblocks both production admin onboarding and the admin-payouts-action
-- smoke / pgTAP tests.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_name     TEXT;
  v_age_raw  TEXT;
  v_age      INTEGER;
  v_role_raw TEXT;
  v_role     public.user_role;
BEGIN
  v_role_raw := NEW.raw_user_meta_data ->> 'role';

  -- Admin path: skip the public.users mirror entirely. We still require the
  -- name field so admin records are tagged; age is optional for admins
  -- because the end-user 18-100 check would be meaningless.
  IF v_role_raw = 'admin' THEN
    v_name := NEW.raw_user_meta_data ->> 'name';
    IF v_name IS NULL OR length(trim(v_name)) = 0 THEN
      RAISE EXCEPTION 'Admin signup missing required metadata: name'
        USING HINT = 'Pass `name` in options.data when creating the admin auth user.';
    END IF;
    RETURN NEW;
  END IF;

  -- End-user path: identical to the trigger body installed in
  -- 20260518191912_roles_and_payouts.sql — mirror into public.users AND
  -- create the role-specific females / males row.
  v_name    := NEW.raw_user_meta_data ->> 'name';
  v_age_raw := NEW.raw_user_meta_data ->> 'age';
  v_age     := NULLIF(v_age_raw, '')::INTEGER;

  IF v_role_raw IS NULL OR v_name IS NULL OR v_age IS NULL THEN
    RAISE EXCEPTION 'Signup missing required metadata: name, age, role'
      USING HINT = 'Pass these in `options.data` when calling supabase.auth.signInWithOtp.';
  END IF;

  v_role := v_role_raw::public.user_role;

  INSERT INTO public.users (id, phone, role, name, age)
  VALUES (NEW.id, NEW.phone, v_role, v_name, v_age);

  IF v_role = 'female' THEN
    INSERT INTO public.females (id) VALUES (NEW.id);
  ELSE
    INSERT INTO public.males (id) VALUES (NEW.id);
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.handle_new_user() IS
  'AFTER INSERT trigger on auth.users. Mirrors end-user (female/male) signups into public.users. Admin signups are recognised but NOT mirrored — admins live off-database and are gated via is_admin() reading JWT user_metadata.';
