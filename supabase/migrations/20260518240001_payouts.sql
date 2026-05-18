-- =============================================================================
-- PAYOUTS — female-initiated withdrawal of earnings, admin-mediated.
--
-- State machine:
--   request ─► pending ─► approved ─► completed | failed
--              │
--              └────► rejected | cancelled
--
-- All non-success terminal states (rejected / failed / cancelled) refund the
-- escrowed coins via credit_female_earnings('payout_failed_reversal').
--
-- Phase 1 limitation: the actual money transfer happens OUTSIDE the system.
-- Admin pays via Razorpay dashboard / bank / UPI, then records the UTR when
-- transitioning approved → completed. The state machine is designed so a
-- future Razorpay Payouts integration can automate that final step without
-- touching the upstream code paths.
--
-- Notification-type adaptation (relative to the prompt template):
--   The notification_type enum already carried `payout_processed` and
--   `payout_rejected` slots from Prompt G. We re-use `payout_processed` for
--   the "completed" notification (semantically identical) and only ALTER
--   in the four genuinely-new values: payout_requested / payout_approved /
--   payout_failed / payout_cancelled. Keeps the enum lean.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Extend notification_type — only the values that don't already exist.
-- ---------------------------------------------------------------------------
ALTER TYPE public.notification_type ADD VALUE IF NOT EXISTS 'payout_requested';
ALTER TYPE public.notification_type ADD VALUE IF NOT EXISTS 'payout_approved';
ALTER TYPE public.notification_type ADD VALUE IF NOT EXISTS 'payout_failed';
ALTER TYPE public.notification_type ADD VALUE IF NOT EXISTS 'payout_cancelled';
-- payout_processed (= completed) and payout_rejected already exist from Prompt G.

-- ---------------------------------------------------------------------------
-- payout_status enum
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'payout_status') THEN
    CREATE TYPE public.payout_status AS ENUM (
      'pending',
      'approved',
      'completed',
      'failed',
      'rejected',
      'cancelled'
    );
  END IF;
END$$;

COMMENT ON TYPE public.payout_status IS
  'State machine for payouts. pending → approved → completed|failed; pending → rejected|cancelled. Non-success terminal states refund escrowed coins.';

-- ---------------------------------------------------------------------------
-- is_admin() — SECURITY DEFINER helper that keys off the JWT user_metadata.
--
-- WHY NOT current_user_role(): the user_role enum (init migration) is
-- deliberately end-user-only ('female', 'male'). Admins log into a separate
-- web dashboard, so there is no public.users row for them. We read the
-- admin claim straight off the JWT to gate admin RLS without polluting the
-- end-user role enum.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    (current_setting('request.jwt.claims', true)::jsonb
       -> 'user_metadata' ->> 'role') = 'admin',
    FALSE
  );
$$;

COMMENT ON FUNCTION public.is_admin() IS
  'Returns TRUE when the caller''s JWT user_metadata.role is "admin". Admin is a separate auth surface (no public.users row), so we cannot key off current_user_role(). Safe to call from RLS policies.';

GRANT EXECUTE ON FUNCTION public.is_admin() TO authenticated;

-- ---------------------------------------------------------------------------
-- payouts table
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.payouts (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  female_id UUID NOT NULL REFERENCES public.users (id) ON DELETE RESTRICT,

  -- Amount fields — all snapshotted at request time so rate-config changes
  -- don't retroactively alter in-flight payouts.
  coins_requested              INTEGER NOT NULL CHECK (coins_requested > 0),
  coin_value_paisa_snapshot    INTEGER NOT NULL CHECK (coin_value_paisa_snapshot > 0),
  commission_pct_snapshot      NUMERIC(5,2) NOT NULL
    CHECK (commission_pct_snapshot >= 0 AND commission_pct_snapshot < 100),
  payout_amount_paisa          INTEGER NOT NULL CHECK (payout_amount_paisa > 0),

  -- Frozen copy of payout_details at request time. Schema:
  --   { method: 'bank', account_holder_name, account_number, ifsc_code }
  --   { method: 'upi',  upi_id }
  payout_method_snapshot       JSONB NOT NULL,

  status public.payout_status NOT NULL DEFAULT 'pending',

  -- Timestamps — one per terminal transition.
  requested_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  approved_at   TIMESTAMPTZ,
  completed_at  TIMESTAMPTZ,
  failed_at     TIMESTAMPTZ,
  rejected_at   TIMESTAMPTZ,
  cancelled_at  TIMESTAMPTZ,

  -- Admin attribution. References auth.users (NOT public.users) because
  -- admins live entirely off-database — they have an auth.users row but
  -- no public.users mirror (see handle_new_user trigger). SET NULL on user
  -- delete so payout history survives the admin's offboarding.
  approved_by  UUID REFERENCES auth.users (id) ON DELETE SET NULL,
  completed_by UUID REFERENCES auth.users (id) ON DELETE SET NULL,
  failed_by    UUID REFERENCES auth.users (id) ON DELETE SET NULL,
  rejected_by  UUID REFERENCES auth.users (id) ON DELETE SET NULL,

  -- Reason / detail fields gated by the CHECK constraints below.
  rejection_reason TEXT,
  failure_reason   TEXT,
  admin_notes      TEXT,
  utr_number       TEXT,  -- UTR or Razorpay txn ref; required at completed.

  -- Ledger linkage.
  escrow_earning_id UUID NOT NULL,  -- female_earnings.id for the debit
  refund_earning_id UUID,           -- female_earnings.id for refund (rejected/failed/cancelled)

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- ----------------------------------------------------------------------
  -- State-machine CHECK constraints.
  -- Every terminal state must carry the right attribution + reason set.
  -- ----------------------------------------------------------------------
  CONSTRAINT payouts_approved_has_admin CHECK (
    status NOT IN ('approved', 'completed', 'failed')
    OR (approved_at IS NOT NULL AND approved_by IS NOT NULL)
  ),
  CONSTRAINT payouts_completed_has_utr CHECK (
    status <> 'completed'
    OR (completed_at IS NOT NULL AND completed_by IS NOT NULL AND utr_number IS NOT NULL)
  ),
  CONSTRAINT payouts_failed_has_reason CHECK (
    status <> 'failed'
    OR (failed_at IS NOT NULL AND failed_by IS NOT NULL AND failure_reason IS NOT NULL)
  ),
  CONSTRAINT payouts_rejected_has_reason CHECK (
    status <> 'rejected'
    OR (rejected_at IS NOT NULL AND rejected_by IS NOT NULL AND rejection_reason IS NOT NULL)
  ),
  CONSTRAINT payouts_cancelled_has_timestamp CHECK (
    status <> 'cancelled' OR cancelled_at IS NOT NULL
  ),
  -- All non-success terminal states must reference the refund ledger entry.
  CONSTRAINT payouts_refunded_has_refund_earning CHECK (
    status NOT IN ('rejected', 'failed', 'cancelled')
    OR refund_earning_id IS NOT NULL
  )
);

COMMENT ON TABLE public.payouts IS
  'Female-initiated withdrawal requests. State machine with admin approval. Coins escrowed via credit_female_earnings(''payout'') on request; refunded via ''payout_failed_reversal'' on any non-success terminal state.';
COMMENT ON COLUMN public.payouts.coin_value_paisa_snapshot IS
  'Value of 1 coin in paisa at request time. Frozen — future rate changes do not affect in-flight payouts.';
COMMENT ON COLUMN public.payouts.commission_pct_snapshot IS
  'Platform commission percentage at request time. 30.00 = platform retains 30%.';
COMMENT ON COLUMN public.payouts.payout_amount_paisa IS
  'INR payable in paisa. Formula: floor(coins × coin_value_paisa × (1 - commission_pct/100)).';
COMMENT ON COLUMN public.payouts.payout_method_snapshot IS
  'JSONB snapshot of payout_details at request time. Admin sees what the female intended even if she later edits her details.';
COMMENT ON COLUMN public.payouts.utr_number IS
  'Bank UTR / Razorpay transaction reference. Required when transitioning to completed.';

-- ---------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------

-- Hard guarantee: at most one active (pending or approved) payout per female.
-- Concurrent payouts-request callers race on this insert; one wins, others
-- get 23505 unique_violation, which payouts-request converts to a 409.
CREATE UNIQUE INDEX IF NOT EXISTS payouts_one_active_per_female_idx
  ON public.payouts (female_id)
  WHERE status IN ('pending', 'approved');

COMMENT ON INDEX public.payouts_one_active_per_female_idx IS
  'Partial unique — one in-flight payout per female. Active = pending OR approved. Terminal payouts (completed/rejected/failed/cancelled) are not constrained.';

-- Female's own history list.
CREATE INDEX IF NOT EXISTS payouts_female_id_created_at_idx
  ON public.payouts (female_id, created_at DESC);

-- Admin dashboard — pending tray (next-action queue).
CREATE INDEX IF NOT EXISTS payouts_pending_created_at_idx
  ON public.payouts (created_at DESC)
  WHERE status = 'pending';

-- Admin dashboard — approved-but-not-completed (in-flight transfers).
CREATE INDEX IF NOT EXISTS payouts_approved_created_at_idx
  ON public.payouts (created_at DESC)
  WHERE status = 'approved';

CREATE INDEX IF NOT EXISTS payouts_status_idx ON public.payouts (status);

-- ---------------------------------------------------------------------------
-- updated_at trigger
-- ---------------------------------------------------------------------------
DROP TRIGGER IF EXISTS payouts_set_updated_at ON public.payouts;
CREATE TRIGGER payouts_set_updated_at
  BEFORE UPDATE ON public.payouts
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- ---------------------------------------------------------------------------
-- RLS — female sees own; admin (via JWT claim) sees all.
-- No INSERT/UPDATE/DELETE policies — Edge Functions own all writes.
-- ---------------------------------------------------------------------------
ALTER TABLE public.payouts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS payouts_select_own ON public.payouts;
CREATE POLICY payouts_select_own
  ON public.payouts
  FOR SELECT
  USING (auth.uid() = female_id);

DROP POLICY IF EXISTS payouts_admin_select_all ON public.payouts;
CREATE POLICY payouts_admin_select_all
  ON public.payouts
  FOR SELECT
  USING (public.is_admin());

COMMENT ON POLICY payouts_select_own       ON public.payouts IS
  'Female reads her own payouts. No write policies — all transitions go through Edge Functions under service_role.';
COMMENT ON POLICY payouts_admin_select_all ON public.payouts IS
  'Admin (JWT user_metadata.role=admin) reads ALL payouts. Read-only at the RLS layer; writes still go through admin-payouts-action under service_role.';
