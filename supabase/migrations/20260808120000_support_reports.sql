-- =============================================================================
-- SUPPORT_REPORTS — "Report an Issue" support tickets
--
-- Distinct from public.reports, which is user-to-user moderation and always
-- names a reported_id. This table backs the in-app support form: a category,
-- free text, and an optional screenshot. There is no accused party.
--
-- Filling a gap, not adding a feature: the mobile client has been inserting
-- into `public.support_reports` since the support form shipped, and the table
-- was never created. Every submission failed against a real database with
-- PGRST205 (relation not found); it only appeared to work under DEV_MODE,
-- where the API layer short-circuits to a simulated success.
--
-- Screenshots are R2 object keys under reports/evidence/{uid}/… produced by
-- the `media-sign` Edge Function (category=reports, PRIVATE). The bytes never
-- touch Postgres — this column holds the key only, read back via presigned
-- GET, same as verification photos.
-- =============================================================================

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'support_issue_type') THEN
    CREATE TYPE public.support_issue_type AS ENUM (
      'bug',
      'account',
      'payment',
      'user_behavior',
      'other'
    );
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'support_report_status') THEN
    CREATE TYPE public.support_report_status AS ENUM (
      'open',
      'in_progress',
      'resolved',
      'closed'
    );
  END IF;
END$$;

COMMENT ON TYPE public.support_issue_type IS
  'Category picked by the user on the Report an Issue form.';
COMMENT ON TYPE public.support_report_status IS
  'Support ticket lifecycle: open → in_progress → resolved|closed.';

-- ---------------------------------------------------------------------------
-- Table
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.support_reports (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),

  -- DEFAULT auth.uid() so an RLS-scoped INSERT from the client never has to
  -- trust a caller-supplied user_id.
  user_id UUID NOT NULL DEFAULT auth.uid() REFERENCES public.users (id) ON DELETE CASCADE,

  type public.support_issue_type NOT NULL,
  description TEXT NOT NULL CHECK (char_length(description) BETWEEN 10 AND 2000),

  -- R2 object key, never a device-local file:// path.
  screenshot_path TEXT CHECK (screenshot_path IS NULL OR char_length(screenshot_path) <= 512),

  status public.support_report_status NOT NULL DEFAULT 'open',

  -- Admins live off-DB (no public.users mirror), same as reports.admin_id.
  admin_id    UUID REFERENCES auth.users (id) ON DELETE SET NULL,
  admin_notes TEXT,
  resolved_at TIMESTAMPTZ,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT support_reports_resolved_consistency CHECK (
    CASE status
      WHEN 'open'        THEN resolved_at IS NULL
      WHEN 'in_progress' THEN resolved_at IS NULL
      ELSE resolved_at IS NOT NULL
    END
  )
);

COMMENT ON TABLE public.support_reports IS
  'In-app "Report an Issue" support tickets. RLS: author sees own; admin sees all (is_admin()).';
COMMENT ON COLUMN public.support_reports.description IS
  'Free-text description, 10..2000 chars. The 10-char floor mirrors the client-side minimum.';
COMMENT ON COLUMN public.support_reports.screenshot_path IS
  'Optional R2 object key (reports/evidence/{uid}/…) from media-sign. NOT a local device URI.';

-- ---------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS support_reports_user_id_idx ON public.support_reports (user_id);
CREATE INDEX IF NOT EXISTS support_reports_status_idx  ON public.support_reports (status);

-- Admin queue — oldest-open first.
CREATE INDEX IF NOT EXISTS support_reports_open_queue_idx
  ON public.support_reports (created_at)
  WHERE status = 'open';

DROP TRIGGER IF EXISTS support_reports_set_updated_at ON public.support_reports;
CREATE TRIGGER support_reports_set_updated_at
  BEFORE UPDATE ON public.support_reports
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- ---------------------------------------------------------------------------
-- RLS
--
-- INSERT/SELECT are client-facing (the form posts directly via PostgREST —
-- there is no support Edge Function). Updates are admin-only: a user must not
-- be able to reopen or rewrite a ticket after filing it.
-- ---------------------------------------------------------------------------
ALTER TABLE public.support_reports ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS support_reports_insert_own ON public.support_reports;
CREATE POLICY support_reports_insert_own
  ON public.support_reports
  FOR INSERT
  TO authenticated
  WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS support_reports_select_own ON public.support_reports;
CREATE POLICY support_reports_select_own
  ON public.support_reports
  FOR SELECT
  TO authenticated
  USING (user_id = auth.uid() OR public.is_admin());

DROP POLICY IF EXISTS support_reports_update_admin ON public.support_reports;
CREATE POLICY support_reports_update_admin
  ON public.support_reports
  FOR UPDATE
  TO authenticated
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- PostgREST caches the schema; without this the new table 404s until reload.
NOTIFY pgrst, 'reload schema';
