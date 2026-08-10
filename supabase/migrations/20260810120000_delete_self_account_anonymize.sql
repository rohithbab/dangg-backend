-- =============================================================================
-- Migration: Self-delete = soft-delete + identity sever ("fresh on re-login")
--
-- Requirement: when a user taps "Delete account", from THEIR point of view the
-- account is gone — re-opening the app and signing in with the same phone must
-- start a brand-new registration. But the admin/moderation team must keep the
-- user's chats, earnings, payments, reports, etc. on the backend.
--
-- The old delete_self_account() only flipped is_active=false + deletion_requested_at.
-- That retained the data (good) but left the phone bound to both the auth.users
-- and public.users rows, so a re-login would resolve to the SAME dormant account
-- (and complete_signup_profile()'s `phone = EXCLUDED.phone` upsert would collide
-- with the UNIQUE phone constraint). So this migration additionally FREES the
-- phone and severs the GoTrue identity:
--
--   * public.users  — keep the row (and everything FK'd to it) for admin, mark
--                     it deleted, archive the phone into deleted_phone, and move
--                     the live `phone` off its real value (a unique tombstone).
--   * auth.users    — null the phone + phone_confirmed_at so GoTrue no longer
--                     resolves it and can never sign into this record again.
--   * auth.identities — drop the caller's identity rows (OTP-only app, so these
--                     are all phone identities) to fully detach the phone.
--
-- After this, LOGIN with the same phone fails "account not found" (routes to
-- signup) and SIGNUP mints a NEW auth.users id → a fresh public.users +
-- females/males row, fully decoupled from the retained old record.
--
-- No purge cron deletes soft-deleted users, so the retained data persists for
-- the admin team indefinitely.
--
-- SECURITY DEFINER (owner = supabase_admin, superuser) so it can write across
-- the auth schema; it only ever touches rows keyed to auth.uid().
-- =============================================================================

-- Archive column: preserves the original phone for admin once the live value is
-- freed for reuse. NULL for every non-deleted account.
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS deleted_phone TEXT;

COMMENT ON COLUMN public.users.deleted_phone IS
  'Original phone, archived here on self-delete so admin retains it while the '
  'live `phone` column is freed (tombstoned) for a fresh re-registration.';

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

  -- 1) Retain the profile row (and all chat/earnings/payment/report data FK'd
  --    to it) for the admin team, but mark it deleted, archive the phone, and
  --    move the live UNIQUE `phone` off its real value so it can be reclaimed.
  UPDATE public.users
  SET is_active             = FALSE,
      deletion_requested_at = NOW(),
      deleted_phone         = COALESCE(deleted_phone, phone),
      phone                 = 'deleted:' || v_uid::text
  WHERE id = v_uid;

  -- 2) Sever the GoTrue identity: free the phone and make this auth user
  --    unreachable. A future signup with the same phone mints a NEW user id.
  UPDATE auth.users
  SET phone              = NULL,
      phone_confirmed_at = NULL
  WHERE id = v_uid;

  DELETE FROM auth.identities
  WHERE user_id = v_uid;
END;
$$;

GRANT EXECUTE ON FUNCTION public.delete_self_account() TO authenticated;

COMMENT ON FUNCTION public.delete_self_account() IS
  'Self-service account deletion. Soft-deletes public.users (data retained for '
  'admin) and frees the phone + severs the GoTrue identity so the same phone '
  're-registers as a brand-new user.';
