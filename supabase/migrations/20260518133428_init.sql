-- =============================================================================
-- Initial Migration: Foundation Schema
--
-- Creates the minimum surface needed for Supabase Auth to function:
--   * `user_role` enum
--   * `public.users` table mirroring `auth.users`
--   * `set_updated_at` trigger function (reused across every future table)
--   * `handle_new_user` auth hook (auto-creates a profile row on signup)
--   * RLS policies: default deny, explicit self-read + self-update
--
-- Every future migration MUST:
--   * Add NEW objects only — never edit this file post-deploy.
--   * Enable RLS on every new table immediately after creation.
--   * Index every foreign key and any column used in WHERE / ORDER BY.
--   * Use TIMESTAMPTZ (never TIMESTAMP) and explicit ON DELETE behaviour.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Required extensions. Both ship with Supabase Postgres but enabling them
-- explicitly makes the migration replayable on any vanilla Postgres 15.
-- -----------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- -----------------------------------------------------------------------------
-- Role enum. Admin auth is intentionally a separate flow — admins are NOT
-- represented as a value here.
-- -----------------------------------------------------------------------------
CREATE TYPE user_role AS ENUM ('female', 'male');

COMMENT ON TYPE user_role IS
  'End-user role. Admin auth is a separate system and is not represented here.';

-- =============================================================================
-- USERS TABLE
--
-- Shared profile fields for every authenticated end-user. Role-specific
-- columns live in `females` and `males` tables (added in later migrations).
-- =============================================================================
CREATE TABLE public.users (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  phone TEXT UNIQUE NOT NULL,
  role user_role NOT NULL,
  name TEXT NOT NULL CHECK (char_length(name) BETWEEN 2 AND 100),
  age INTEGER NOT NULL CHECK (age BETWEEN 18 AND 100),
  profile_picture_url TEXT,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  is_suspended BOOLEAN NOT NULL DEFAULT FALSE,
  deletion_requested_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.users IS
  'Shared profile for all end-users. Role-specific data in females / males tables.';
COMMENT ON COLUMN public.users.deletion_requested_at IS
  'Set when the user initiates DPDP account deletion. A daily cron permanently deletes the account 30 days later.';
COMMENT ON COLUMN public.users.is_active IS
  'Soft-delete flag. False = hidden from listings; row is retained until cron deletion runs.';
COMMENT ON COLUMN public.users.is_suspended IS
  'Set by admin. Blocks login until cleared.';

CREATE INDEX users_phone_idx ON public.users(phone);
CREATE INDEX users_role_idx ON public.users(role);
CREATE INDEX users_active_idx ON public.users(is_active) WHERE is_active = TRUE;

-- =============================================================================
-- SHARED TRIGGER: maintain `updated_at` on every UPDATE
--
-- Every table that exposes `updated_at` adds a `BEFORE UPDATE` trigger that
-- calls this function. Keep the function side-effect-free — adding side
-- effects here would silently affect every table that uses it.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.set_updated_at() IS
  'BEFORE UPDATE trigger function. Sets NEW.updated_at = NOW(). Attach to every table with an updated_at column.';

CREATE TRIGGER users_set_updated_at
  BEFORE UPDATE ON public.users
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- =============================================================================
-- ROW LEVEL SECURITY — default deny, explicit grants
-- =============================================================================
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;

-- Users may read their own row.
CREATE POLICY users_select_own
  ON public.users
  FOR SELECT
  USING (auth.uid() = id);

-- Users may update their own row, but cannot change role or phone (those
-- are anchored to the auth identity and migration paths exist separately).
CREATE POLICY users_update_own
  ON public.users
  FOR UPDATE
  USING (auth.uid() = id)
  WITH CHECK (
    auth.uid() = id
    AND role = (SELECT role FROM public.users WHERE id = auth.uid())
    AND phone = (SELECT phone FROM public.users WHERE id = auth.uid())
  );

COMMENT ON POLICY users_select_own ON public.users IS
  'Authenticated users see only their own profile row.';
COMMENT ON POLICY users_update_own ON public.users IS
  'Authenticated users may patch their own row except role and phone.';

-- =============================================================================
-- AUTH HOOK: auto-create public.users row when auth.users row is created
--
-- Supabase's signup flow writes to auth.users. We mirror the row into
-- public.users so application code only ever joins on the public schema.
-- The required profile fields come from `raw_user_meta_data`, which the
-- mobile app populates during `supabase.auth.signInWithOtp({ phone, ... })`.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_name TEXT;
  v_age INTEGER;
  v_role user_role;
BEGIN
  v_name := NEW.raw_user_meta_data->>'name';
  v_age := NULLIF(NEW.raw_user_meta_data->>'age', '')::INTEGER;
  v_role := (NEW.raw_user_meta_data->>'role')::user_role;

  IF v_name IS NULL OR v_age IS NULL OR v_role IS NULL THEN
    RAISE EXCEPTION 'Signup missing required metadata: name, age, role'
      USING HINT = 'Pass these in `options.data` when calling supabase.auth.signInWithOtp.';
  END IF;

  INSERT INTO public.users (id, phone, role, name, age)
  VALUES (NEW.id, NEW.phone, v_role, v_name, v_age);

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.handle_new_user() IS
  'AFTER INSERT trigger on auth.users. Mirrors the new auth row into public.users with profile metadata.';

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_user();
