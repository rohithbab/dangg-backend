-- =============================================================================
-- Deferred-profile signup (Phone → OTP → Profile)
--
-- The app's signup UI now collects name/age/role on a Profile screen AFTER OTP
-- verification, not before. But Supabase creates the auth.users row at
-- signInWithOtp (the Phone step), where `handle_new_user` previously REQUIRED
-- name/age/role in raw_user_meta_data and aborted otherwise.
--
-- This migration:
--   1. Relaxes handle_new_user so an end-user signup WITHOUT name/age/role is
--      allowed — the auth user is created, the public.users mirror is deferred.
--      (When metadata IS present, behaviour is unchanged — back-compat.)
--   2. Adds complete_signup_profile(name, age, role) — called from the Profile
--      screen once authenticated — which creates/updates the public.users row
--      and the role-specific females/males row for the current user.
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

  -- Admin path: skip the public.users mirror entirely (admins live off-DB).
  IF v_role_raw = 'admin' THEN
    v_name := NEW.raw_user_meta_data ->> 'name';
    IF v_name IS NULL OR length(trim(v_name)) = 0 THEN
      RAISE EXCEPTION 'Admin signup missing required metadata: name'
        USING HINT = 'Pass `name` in options.data when creating the admin auth user.';
    END IF;
    RETURN NEW;
  END IF;

  v_name    := NEW.raw_user_meta_data ->> 'name';
  v_age_raw := NEW.raw_user_meta_data ->> 'age';
  v_age     := NULLIF(v_age_raw, '')::INTEGER;

  -- Deferred-profile path: no name/age/role yet. Allow the auth user to be
  -- created; the profile is completed later via complete_signup_profile().
  IF v_role_raw IS NULL OR v_name IS NULL OR v_age IS NULL THEN
    RETURN NEW;
  END IF;

  -- Eager path (metadata present) — original behaviour, kept for back-compat.
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
  'AFTER INSERT trigger on auth.users. Mirrors end-user signups into public.users when name/age/role metadata is present; otherwise defers the mirror to complete_signup_profile(). Admins are recognised but not mirrored.';

-- Completes a deferred signup: creates/updates public.users + the role row for
-- the authenticated caller. SECURITY DEFINER so it can write across RLS; only
-- ever writes rows keyed to auth.uid().
CREATE OR REPLACE FUNCTION public.complete_signup_profile(
  p_name TEXT,
  p_age  INTEGER,
  p_role public.user_role
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid   UUID := auth.uid();
  v_phone TEXT;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;
  IF p_name IS NULL OR length(trim(p_name)) = 0 THEN
    RAISE EXCEPTION 'Profile name is required';
  END IF;
  IF p_age IS NULL OR p_age < 18 OR p_age > 100 THEN
    RAISE EXCEPTION 'Profile age must be between 18 and 100';
  END IF;

  SELECT phone INTO v_phone FROM auth.users WHERE id = v_uid;

  INSERT INTO public.users (id, phone, role, name, age)
  VALUES (v_uid, v_phone, p_role, trim(p_name), p_age)
  ON CONFLICT (id) DO UPDATE
    SET name = EXCLUDED.name,
        age  = EXCLUDED.age,
        role = EXCLUDED.role,
        phone = EXCLUDED.phone;

  IF p_role = 'female' THEN
    INSERT INTO public.females (id) VALUES (v_uid) ON CONFLICT (id) DO NOTHING;
  ELSE
    INSERT INTO public.males (id) VALUES (v_uid) ON CONFLICT (id) DO NOTHING;
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.complete_signup_profile(TEXT, INTEGER, public.user_role) TO authenticated;

COMMENT ON FUNCTION public.complete_signup_profile(TEXT, INTEGER, public.user_role) IS
  'Completes a deferred Phone→OTP→Profile signup: upserts public.users and creates the females/males row for auth.uid().';
