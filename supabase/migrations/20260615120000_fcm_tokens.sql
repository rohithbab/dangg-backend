-- =============================================================================
-- FCM device tokens — one row per device push token, used by the notify()
-- helper to fan out push notifications. The push sender reads these with the
-- service role (bypasses RLS); end users may only see/modify their own.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.fcm_tokens (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  token        TEXT NOT NULL UNIQUE,
  platform     TEXT NOT NULL CHECK (platform IN ('android', 'ios', 'web')),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS fcm_tokens_user_id_idx ON public.fcm_tokens (user_id);

ALTER TABLE public.fcm_tokens ENABLE ROW LEVEL SECURITY;

-- A device token belongs to whoever is logged in on that device. The
-- fcm-register Edge Function upserts with the service role so a token can be
-- re-assigned to a new user (shared/handed-down device); these policies cover
-- any direct client access.
CREATE POLICY "fcm_tokens_select_own" ON public.fcm_tokens
  FOR SELECT TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "fcm_tokens_insert_own" ON public.fcm_tokens
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY "fcm_tokens_update_own" ON public.fcm_tokens
  FOR UPDATE TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
CREATE POLICY "fcm_tokens_delete_own" ON public.fcm_tokens
  FOR DELETE TO authenticated USING (auth.uid() = user_id);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.fcm_tokens TO authenticated;
