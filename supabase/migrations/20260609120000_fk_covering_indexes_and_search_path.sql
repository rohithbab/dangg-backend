-- =============================================================================
-- DB hardening: covering indexes for foreign keys + pinned search_path
--
-- Two advisor-driven fixes, both additive and idempotent:
--
--   1. UNINDEXED FOREIGN KEYS
--      The init migration mandates "Index every foreign key", but eight FKs
--      shipped without a covering index. Each one forces a sequential scan
--      whenever Postgres enforces the FK's ON DELETE action (e.g. an admin
--      auth.users row being removed must scan payouts/reports to SET NULL),
--      and whenever application code joins/filters on the column.
--
--      All eight target low-selectivity / mostly-NULL attribution columns, so
--      they use PARTIAL indexes (WHERE col IS NOT NULL). A partial index still
--      fully covers the FK — a delete of a referenced id only ever matches
--      non-NULL rows — while staying small and cheap to maintain on write.
--
--   2. MUTABLE search_path ON A SECURITY DEFINER FUNCTION
--      verify_current_password() is SECURITY DEFINER but never pinned its
--      search_path (advisor: function_search_path_mutable). A definer function
--      with a caller-controlled search_path is a privilege-escalation vector.
--      It's an OTP-era stub that always returns TRUE; we re-declare it with an
--      empty search_path so no unqualified name can be hijacked.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Covering indexes for the unindexed foreign keys.
-- -----------------------------------------------------------------------------

-- chat_sessions.ended_by → users(id) (ON DELETE SET NULL). NULL while active.
CREATE INDEX IF NOT EXISTS chat_sessions_ended_by_idx
  ON public.chat_sessions (ended_by)
  WHERE ended_by IS NOT NULL;

-- payments.package_id → coin_packages(id) (ON DELETE RESTRICT). Always set;
-- a plain index supports "payments for package X" admin analytics + the
-- RESTRICT check when retiring a package.
CREATE INDEX IF NOT EXISTS payments_package_id_idx
  ON public.payments (package_id);

-- payouts admin-attribution columns → auth.users(id) (ON DELETE SET NULL).
-- Mostly NULL until an admin acts; partial indexes keep them lean.
CREATE INDEX IF NOT EXISTS payouts_approved_by_idx
  ON public.payouts (approved_by)
  WHERE approved_by IS NOT NULL;
CREATE INDEX IF NOT EXISTS payouts_completed_by_idx
  ON public.payouts (completed_by)
  WHERE completed_by IS NOT NULL;
CREATE INDEX IF NOT EXISTS payouts_failed_by_idx
  ON public.payouts (failed_by)
  WHERE failed_by IS NOT NULL;
CREATE INDEX IF NOT EXISTS payouts_rejected_by_idx
  ON public.payouts (rejected_by)
  WHERE rejected_by IS NOT NULL;

-- reports.admin_id → auth.users(id) (ON DELETE SET NULL). NULL until reviewed.
CREATE INDEX IF NOT EXISTS reports_admin_id_idx
  ON public.reports (admin_id)
  WHERE admin_id IS NOT NULL;

-- reports.context_chat_request_id → chat_requests(id) (ON DELETE SET NULL).
-- Optional context; partial keeps it to reports that actually reference a chat.
CREATE INDEX IF NOT EXISTS reports_context_chat_request_id_idx
  ON public.reports (context_chat_request_id)
  WHERE context_chat_request_id IS NOT NULL;

-- -----------------------------------------------------------------------------
-- 2. Pin search_path on verify_current_password (SECURITY DEFINER stub).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.verify_current_password(p_password text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- Dangg is OTP-based; there is no password to verify. Returns TRUE so the
  -- mobile "confirm password" compatibility flow succeeds. p_password is
  -- intentionally unused.
  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION public.verify_current_password(text) TO authenticated;

COMMENT ON FUNCTION public.verify_current_password(text) IS
  'OTP-era compatibility stub: always TRUE. SECURITY DEFINER with empty search_path so no unqualified identifier can be hijacked.';
