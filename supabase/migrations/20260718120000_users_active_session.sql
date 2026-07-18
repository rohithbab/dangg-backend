-- =============================================================================
-- Single-device login — "kick" marker.
--
-- Two-layer design:
--   1. Real enforcement is GOTRUE_SESSIONS_SINGLE_PER_USER=true (self-host env,
--      applied separately) — GoTrue revokes a user's other refresh tokens the
--      moment a new one is issued, so an old device's session actually stops
--      working. That setting alone is sufficient for security but the old
--      device wouldn't notice until its access token next tries to refresh
--      (up to ~1h later, silently).
--   2. This column exists purely for a fast, friendly UX: every device writes
--      a fresh id here on login and subscribes to Realtime on its own row. A
--      mismatch means another device just logged in, so the app can sign out
--      immediately and say why, instead of the user hitting a mystery 401.
--      Not a security boundary by itself — a tampered client could ignore it,
--      but its refresh token is already dead per (1) regardless.
-- =============================================================================

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS active_session_id UUID;

COMMENT ON COLUMN public.users.active_session_id IS
  'Marker for the most recently logged-in device (see migration header). Each device compares this against its own locally-stored id via Realtime to detect it has been replaced.';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'users'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.users;
  END IF;
END$$;
