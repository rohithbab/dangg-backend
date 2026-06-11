-- =============================================================================
-- Migration: Sync role claim to auth.users.raw_app_meta_data
--
-- Updates the `handle_new_user()` trigger function on auth.users creation to
-- write the user's role (female/male/admin) directly to `raw_app_meta_data`.
--
-- This guarantees that the JWT app_metadata contains the role (e.g. role='female'),
-- which enables correct role extraction in the frontend.
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
    -- Write role='admin' to raw_app_meta_data
    UPDATE auth.users
    SET raw_app_meta_data = jsonb_set(COALESCE(raw_app_meta_data, '{}'::jsonb), '{role}', '"admin"')
    WHERE id = NEW.id;
    RETURN NEW;
  END IF;

  -- End-user path: mirror into public.users AND create the role-specific females / males row.
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

  -- Sync role to auth.users.raw_app_meta_data so it propagates to JWT claims
  UPDATE auth.users
  SET raw_app_meta_data = jsonb_set(COALESCE(raw_app_meta_data, '{}'::jsonb), '{role}', to_jsonb(v_role_raw))
  WHERE id = NEW.id;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.handle_new_user() IS
  'AFTER INSERT trigger on auth.users. Mirrors end-user (female/male) signups into public.users and sets role in auth.users.raw_app_meta_data for JWT propagation.';
