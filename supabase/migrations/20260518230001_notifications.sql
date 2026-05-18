-- =============================================================================
-- NOTIFICATIONS — in-app inbox + Realtime broadcast
--
-- Phase 1 covers chat-request events. Future events (payments, payouts,
-- verification, suspension, system) reserve enum slots so they can be
-- added without an ALTER TYPE migration.
--
-- Delivery channels in Phase 1:
--   * In-app (this table read directly via PostgREST under the SELECT RLS).
--   * Realtime (table added to `supabase_realtime` publication; the mobile
--     app subscribes on `recipient_id=eq.<self>` for live toasts).
--
-- FCM / email / SMS are deliberately deferred. When FCM lands, the single
-- code path to extend is `_shared/notify.ts` — no caller changes needed.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- notification_type enum
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'notification_type') THEN
    CREATE TYPE public.notification_type AS ENUM (
      -- Chat-request flow (Phase 1)
      'chat_request_received',
      'chat_request_accepted',
      'chat_request_declined',
      'chat_request_cancelled',
      'chat_request_expired',
      'chat_request_missed',
      -- Reserved for future prompts; UI will treat unknown types as 'system'
      'payment_success',
      'payment_failed',
      'payout_processed',
      'payout_rejected',
      'verification_approved',
      'verification_rejected',
      'account_suspended',
      'system'
    );
  END IF;
END$$;

COMMENT ON TYPE public.notification_type IS
  'Notification category. Mobile app maps this to an icon + deep-link route. Future event types should be added via ALTER TYPE.';

-- ---------------------------------------------------------------------------
-- notifications table
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.notifications (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  recipient_id UUID NOT NULL REFERENCES public.users (id) ON DELETE CASCADE,
  type public.notification_type NOT NULL,
  title TEXT NOT NULL CHECK (char_length(title) BETWEEN 1 AND 100),
  body  TEXT NOT NULL CHECK (char_length(body)  BETWEEN 1 AND 500),
  -- Structured payload — schema varies by `type`. Used by the app to
  -- deep-link to the relevant screen without extra round-trips.
  data JSONB NOT NULL DEFAULT '{}'::jsonb,
  is_read BOOLEAN NOT NULL DEFAULT FALSE,
  read_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- read_at must be NULL iff is_read is FALSE.
  CONSTRAINT notifications_read_consistency CHECK (
    (is_read = FALSE AND read_at IS NULL)
    OR (is_read = TRUE  AND read_at IS NOT NULL)
  )
);

COMMENT ON TABLE public.notifications IS
  'In-app notification inbox. RLS: recipient selects/updates-read-state own. Realtime-enabled for live toasts. Writes only via service role (the notify() helper or SECURITY DEFINER SQL).';
COMMENT ON COLUMN public.notifications.data IS
  'Structured deep-link payload. Schema varies by notification type — e.g. chat_request_received includes { chat_request_id, from_user_id, from_user_name, chat_cost_coins, expires_at }.';
COMMENT ON COLUMN public.notifications.type IS
  'Notification category. The mobile app picks an icon and deep-link route from this.';

-- ---------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------

-- Inbox list — "my notifications, newest first".
CREATE INDEX IF NOT EXISTS notifications_recipient_id_created_at_idx
  ON public.notifications (recipient_id, created_at DESC);

-- Bell-icon badge count — "my unread notifications". Partial index keeps
-- the badge-count query cheap even at hundreds of millions of rows.
CREATE INDEX IF NOT EXISTS notifications_recipient_id_unread_idx
  ON public.notifications (recipient_id)
  WHERE is_read = FALSE;

-- ---------------------------------------------------------------------------
-- RLS — recipient reads own; recipient updates own read-state ONLY.
--
-- The UPDATE policy's WITH CHECK compares the proposed-NEW row's content
-- columns to the existing row's values fetched via a self-subquery, so any
-- UPDATE that mutates type / title / body / data / recipient_id fails
-- atomically. Only is_read + read_at + updated_at-style columns are mutable.
-- ---------------------------------------------------------------------------
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS notifications_select_own ON public.notifications;
CREATE POLICY notifications_select_own
  ON public.notifications
  FOR SELECT
  USING (auth.uid() = recipient_id);

COMMENT ON POLICY notifications_select_own ON public.notifications IS
  'Recipient reads own notifications. No other reader.';

DROP POLICY IF EXISTS notifications_update_own_read_state ON public.notifications;
CREATE POLICY notifications_update_own_read_state
  ON public.notifications
  FOR UPDATE
  USING (auth.uid() = recipient_id)
  WITH CHECK (
    auth.uid() = recipient_id
    AND type         = (SELECT n.type         FROM public.notifications n WHERE n.id = notifications.id)
    AND title        = (SELECT n.title        FROM public.notifications n WHERE n.id = notifications.id)
    AND body         = (SELECT n.body         FROM public.notifications n WHERE n.id = notifications.id)
    AND data         = (SELECT n.data         FROM public.notifications n WHERE n.id = notifications.id)
    AND recipient_id = (SELECT n.recipient_id FROM public.notifications n WHERE n.id = notifications.id)
  );

COMMENT ON POLICY notifications_update_own_read_state ON public.notifications IS
  'Recipient may UPDATE only the read-state columns (is_read, read_at). Tampering with type / title / body / data / recipient_id is rejected by the WITH CHECK self-subqueries that pin those columns to their existing values.';

-- No INSERT / DELETE policies. INSERTs flow through service-role callers
-- (notify() helper + SECURITY DEFINER SQL functions). DELETEs are not
-- exposed to end users — retention cleanup is admin-only.

-- ---------------------------------------------------------------------------
-- Realtime publication
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename  = 'notifications'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.notifications;
  END IF;
END$$;
