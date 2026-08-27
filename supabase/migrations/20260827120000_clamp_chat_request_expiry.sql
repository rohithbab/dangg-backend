-- =============================================================================
-- CLAMP chat_requests.expires_at TO THE AUTO-DECLINE WINDOW
--
-- The request auto-decline window is 30s. It is set by the `chat-requests-send`
-- Edge Function (TIMEOUT_SECONDS) and mirrored by the app
-- (CHAT_REQUEST_AUTO_DECLINE_S). On self-hosted Supabase, an edge redeploy does
-- not always pick up a changed TIMEOUT_SECONDS immediately, so a stale build can
-- keep writing expires_at = sent_at + 120s. That desyncs the countdown both
-- sides see, lets the female's card reappear for the leftover ~90s, and blocks a
-- retry right after "No Response" (the row still looks pending to the one-pending
-- unique index).
--
-- This BEFORE INSERT trigger makes the DB the authority: it caps expires_at at
-- sent_at + 30s regardless of what the function computed. It is a CAP only — a
-- shorter window, if ever set, is honoured (LEAST). When the Edge Function is on
-- the matching 30s build this trigger is a silent no-op.
--
-- To change the window: update all three in lockstep — this interval, the Edge
-- Function TIMEOUT_SECONDS, and the app's CHAT_REQUEST_AUTO_DECLINE_S.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.clamp_chat_request_expiry()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  -- sent_at is populated by the time a BEFORE trigger runs (explicit value from
  -- the send function, or its column DEFAULT NOW()). Cap, never extend.
  NEW.expires_at := LEAST(NEW.expires_at, NEW.sent_at + INTERVAL '30 seconds');
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS chat_requests_clamp_expiry ON public.chat_requests;
CREATE TRIGGER chat_requests_clamp_expiry
  BEFORE INSERT ON public.chat_requests
  FOR EACH ROW
  EXECUTE FUNCTION public.clamp_chat_request_expiry();

COMMENT ON FUNCTION public.clamp_chat_request_expiry() IS
  'Caps chat_requests.expires_at at sent_at + 30s so the auto-decline window holds even if the send Edge Function lags on a shortened TIMEOUT_SECONDS. Keep the interval in sync with the app CHAT_REQUEST_AUTO_DECLINE_S and the Edge Function TIMEOUT_SECONDS.';
