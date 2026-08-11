-- =============================================================================
-- Migration: delete_self_account also revokes the user's auth sessions
--
-- Follow-up to 20260810120000. That version freed the phone + severed the
-- identity, but left the user's auth.sessions / refresh tokens intact. The
-- app persists the Supabase session locally, so on a reload the client could
-- refresh the JWT off the still-valid refresh token and the "deleted" user
-- came back.
--
-- The app now calls supabase.auth.signOut() on delete (purges the persisted
-- session + revokes server-side), but we ALSO revoke here as defense-in-depth:
-- guarantees the refresh token is dead even for other devices or a stale build
-- that doesn't sign out. Deleting auth.sessions cascades to
-- auth.refresh_tokens (session_id FK ON DELETE CASCADE).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.delete_self_account()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  -- Retain the profile row (+ all FK'd data) for admin; mark deleted, archive
  -- the phone, and free the live UNIQUE phone for a fresh re-registration.
  UPDATE public.users
  SET is_active             = FALSE,
      deletion_requested_at = NOW(),
      deleted_phone         = COALESCE(deleted_phone, phone),
      phone                 = 'deleted:' || v_uid::text
  WHERE id = v_uid;

  -- Free the phone in GoTrue and sever the identity.
  UPDATE auth.users
  SET phone = NULL, phone_confirmed_at = NULL
  WHERE id = v_uid;

  DELETE FROM auth.identities WHERE user_id = v_uid;

  -- Revoke every live session so a saved refresh token can't restore the
  -- deleted user after an app reload. Cascades to auth.refresh_tokens.
  DELETE FROM auth.sessions WHERE user_id = v_uid;
END;
$$;

GRANT EXECUTE ON FUNCTION public.delete_self_account() TO authenticated;
