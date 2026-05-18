-- =============================================================================
-- REPORTS — user-to-user reporting with admin moderation
--
-- State machine: submitted → action_taken | dismissed
-- (`under_review` exists as an intermediate state admins can park reports in
--  while investigating; not directly transitioned by the v1 EFs.)
--
-- Admin actions:
--   * dismissed         — no side effect
--   * warning_issued    — notify('account_warning') sent
--   * account_suspended — flip users.is_suspended=TRUE + notify
--
-- Schema adaptations relative to prompt template:
--   * notification_type already has `account_suspended` (from Prompt G).
--     `account_warning` is added by this migration.
--   * RLS admin-read uses is_admin() (JWT claim, from Prompt H) rather than
--     current_user_role()='admin' — the user_role enum is end-user-only.
--   * reports.admin_id references auth.users (NOT public.users) for the
--     same reason payouts.approved_by does: admins live off-DB.
-- =============================================================================

ALTER TYPE public.notification_type ADD VALUE IF NOT EXISTS 'account_warning';

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'report_reason') THEN
    CREATE TYPE public.report_reason AS ENUM (
      'harassment',
      'inappropriate_content',
      'fake_profile',
      'fraud_scam',
      'spam',
      'underage',
      'other'
    );
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'report_status') THEN
    CREATE TYPE public.report_status AS ENUM (
      'submitted',
      'under_review',
      'action_taken',
      'dismissed'
    );
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'report_admin_action') THEN
    CREATE TYPE public.report_admin_action AS ENUM (
      'none',
      'warning_issued',
      'account_suspended'
    );
  END IF;
END$$;

COMMENT ON TYPE public.report_reason       IS 'Why the reporter is reporting. UI maps these to a category picker.';
COMMENT ON TYPE public.report_status       IS 'Lifecycle: submitted → action_taken|dismissed. under_review is an admin-only park state.';
COMMENT ON TYPE public.report_admin_action IS 'Outcome of an admin review. none = dismissed.';

-- ---------------------------------------------------------------------------
-- reports table
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.reports (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  reporter_id UUID NOT NULL REFERENCES public.users (id) ON DELETE RESTRICT,
  reported_id UUID NOT NULL REFERENCES public.users (id) ON DELETE RESTRICT,
  reason public.report_reason NOT NULL,
  description TEXT CHECK (description IS NULL OR char_length(description) BETWEEN 1 AND 2000),

  -- Optional link to the chat_request that triggered the report.
  context_chat_request_id UUID REFERENCES public.chat_requests (id) ON DELETE SET NULL,

  status public.report_status NOT NULL DEFAULT 'submitted',

  -- Admin attribution. References auth.users because admins have no
  -- public.users mirror (see Prompt H's handle_new_user adjustment).
  admin_id     UUID REFERENCES auth.users (id) ON DELETE SET NULL,
  admin_action public.report_admin_action,
  admin_notes  TEXT,

  reviewed_at  TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT reports_no_self CHECK (reporter_id <> reported_id),

  -- State-machine consistency. CASE returns the boolean required for that
  -- row's status; any other shape fails the check.
  CONSTRAINT reports_terminal_consistency CHECK (
    CASE status
      WHEN 'submitted' THEN
        admin_id IS NULL AND reviewed_at IS NULL AND admin_action IS NULL
      WHEN 'under_review' THEN
        admin_id IS NOT NULL AND reviewed_at IS NULL
      WHEN 'action_taken' THEN
        admin_id IS NOT NULL
        AND reviewed_at IS NOT NULL
        AND admin_action IN ('warning_issued', 'account_suspended')
      WHEN 'dismissed' THEN
        admin_id IS NOT NULL
        AND reviewed_at IS NOT NULL
        AND admin_action = 'none'
    END
  )
);

COMMENT ON TABLE public.reports IS
  'User-submitted reports against other users. Admin reviews and acts. RLS: reporter sees own; admin sees all (via is_admin()).';
COMMENT ON COLUMN public.reports.description IS
  'Optional free-text explanation, 1..2000 chars when present.';
COMMENT ON COLUMN public.reports.context_chat_request_id IS
  'Optional FK to the chat_request that triggered the report. ON DELETE SET NULL — request deletions never block the report.';

-- ---------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS reports_reporter_id_idx ON public.reports (reporter_id);
CREATE INDEX IF NOT EXISTS reports_reported_id_idx ON public.reports (reported_id);
CREATE INDEX IF NOT EXISTS reports_status_idx      ON public.reports (status);

-- Admin queue — oldest-submitted first.
CREATE INDEX IF NOT EXISTS reports_submitted_queue_idx
  ON public.reports (created_at)
  WHERE status = 'submitted';

DROP TRIGGER IF EXISTS reports_set_updated_at ON public.reports;
CREATE TRIGGER reports_set_updated_at
  BEFORE UPDATE ON public.reports
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- ---------------------------------------------------------------------------
-- RLS
--
-- SELECT: reporter sees own; admin (via JWT) sees all. Reported user does
-- NOT see reports against them — anti-retaliation.
-- All writes go through Edge Functions under service_role.
-- ---------------------------------------------------------------------------
ALTER TABLE public.reports ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS reports_select_own ON public.reports;
CREATE POLICY reports_select_own
  ON public.reports
  FOR SELECT
  USING (auth.uid() = reporter_id);

DROP POLICY IF EXISTS reports_admin_select_all ON public.reports;
CREATE POLICY reports_admin_select_all
  ON public.reports
  FOR SELECT
  USING (public.is_admin());

COMMENT ON POLICY reports_select_own       ON public.reports IS
  'Reporter reads their own reports (status visibility). Reported user has no read access — anti-retaliation.';
COMMENT ON POLICY reports_admin_select_all ON public.reports IS
  'Admin (JWT user_metadata.role=admin) reads all reports for the moderation queue.';
