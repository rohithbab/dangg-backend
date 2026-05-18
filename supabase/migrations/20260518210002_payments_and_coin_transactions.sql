-- =============================================================================
-- PAYMENTS + COIN_TRANSACTIONS + credit_coins()
--
-- This migration introduces the money flow. Three new objects:
--   * payments               — one row per payment attempt (state machine)
--   * coin_transactions      — append-only ledger of every coin movement
--   * credit_coins()         — the ONE function any code path uses to mutate
--                              males.coin_balance. Atomic balance update +
--                              ledger insert, locked with FOR UPDATE.
--
-- Direct UPDATE of males.coin_balance is FORBIDDEN from application code;
-- the only writer is `credit_coins`, granted only to the service_role.
--
-- Schema note: this codebase's `males` table uses `id` as its primary key
-- (referencing public.users.id), not `user_id` as the prompt template
-- assumes. Every reference here uses `males.id`.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------
CREATE TYPE payment_status AS ENUM ('initiated', 'captured', 'failed', 'refunded');

COMMENT ON TYPE payment_status IS
  'Payment lifecycle: initiated → captured | failed; captured → refunded.';

CREATE TYPE coin_transaction_type AS ENUM (
  'purchase',         -- coins credited from a Razorpay payment
  'chat_charge',      -- coins debited for sending a chat request
  'chat_refund',      -- coins refunded after chat-request timeout / decline / cancel
  'razorpay_refund',  -- coins debited following a Razorpay refund webhook
  'admin_adjustment'  -- manual adjustment by admin (always audited)
);

COMMENT ON TYPE coin_transaction_type IS
  'Closed set of reasons for a coin-ledger entry. Add new values via migration when new flows land.';

-- =============================================================================
-- payments
-- =============================================================================
CREATE TABLE public.payments (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  male_id UUID NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
  package_id UUID NOT NULL REFERENCES public.coin_packages(id) ON DELETE RESTRICT,

  -- Razorpay identifiers. order_id is unique once issued. payment_id and
  -- signature are populated only on capture. We start with a placeholder
  -- 'pending_<uuid>' value for order_id and patch it after Razorpay assigns one.
  razorpay_order_id TEXT NOT NULL UNIQUE,
  razorpay_payment_id TEXT UNIQUE,
  razorpay_signature TEXT,

  -- Snapshot of the package at purchase time, so changing the catalogue later
  -- doesn't alter historical payments.
  amount_paisa INTEGER NOT NULL CHECK (amount_paisa > 0),
  coins_to_credit INTEGER NOT NULL CHECK (coins_to_credit > 0),

  status payment_status NOT NULL DEFAULT 'initiated',
  failure_reason TEXT,

  captured_at TIMESTAMPTZ,
  failed_at TIMESTAMPTZ,
  refunded_at TIMESTAMPTZ,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- State-machine consistency.
  CONSTRAINT payments_captured_has_identifiers CHECK (
    status <> 'captured'
    OR (
      razorpay_payment_id IS NOT NULL
      AND captured_at IS NOT NULL
    )
  ),
  CONSTRAINT payments_failed_has_timestamp CHECK (
    status <> 'failed' OR failed_at IS NOT NULL
  ),
  CONSTRAINT payments_refunded_has_timestamp CHECK (
    status <> 'refunded' OR refunded_at IS NOT NULL
  )
);

CREATE INDEX payments_male_recent_idx
  ON public.payments(male_id, created_at DESC);
CREATE INDEX payments_razorpay_order_idx
  ON public.payments(razorpay_order_id);
CREATE INDEX payments_status_idx
  ON public.payments(status);

CREATE TRIGGER payments_set_updated_at
  BEFORE UPDATE ON public.payments
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

COMMENT ON TABLE public.payments IS
  'One row per payment attempt. State machine: initiated → captured | failed; captured → refunded. Server-side writes only.';
COMMENT ON COLUMN public.payments.razorpay_signature IS
  'Set only after server-side HMAC verification succeeds during payments-verify.';
COMMENT ON COLUMN public.payments.amount_paisa IS
  'Snapshot of the package price at purchase. Never reference the live catalogue for historical reads.';

-- =============================================================================
-- coin_transactions  — append-only ledger
-- =============================================================================
CREATE TABLE public.coin_transactions (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  male_id UUID NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
  type coin_transaction_type NOT NULL,
  -- Positive for credit, negative for debit. Never zero.
  amount INTEGER NOT NULL CHECK (amount <> 0),
  -- Snapshot of the balance after applying this delta.
  balance_after INTEGER NOT NULL CHECK (balance_after >= 0),
  -- Soft FK into the originating row (payments.id, chat_requests.id, …).
  -- Not a hard FK because the referenced table varies by type.
  reference_id UUID,
  description TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX coin_transactions_male_recent_idx
  ON public.coin_transactions(male_id, created_at DESC);
CREATE INDEX coin_transactions_reference_idx
  ON public.coin_transactions(reference_id)
  WHERE reference_id IS NOT NULL;
CREATE INDEX coin_transactions_type_idx
  ON public.coin_transactions(type);

COMMENT ON TABLE public.coin_transactions IS
  'Append-only ledger of coin movements. balance_after is recorded at insert time, enabling audit reconstruction.';
COMMENT ON COLUMN public.coin_transactions.amount IS
  'Positive = credit, negative = debit. Zero is forbidden by CHECK.';
COMMENT ON COLUMN public.coin_transactions.balance_after IS
  'Snapshot of males.coin_balance after this row was applied.';

-- =============================================================================
-- Row Level Security
-- =============================================================================
ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;
CREATE POLICY payments_select_own
  ON public.payments
  FOR SELECT
  USING (auth.uid() = male_id);
-- No insert / update / delete policies → application writes are service-role only.

ALTER TABLE public.coin_transactions ENABLE ROW LEVEL SECURITY;
CREATE POLICY coin_transactions_select_own
  ON public.coin_transactions
  FOR SELECT
  USING (auth.uid() = male_id);
-- No insert / update / delete policies → the ledger is append-only via the
-- service role, and immutable from the application's perspective.

COMMENT ON POLICY payments_select_own ON public.payments IS
  'Males read only their own payments. All writes go through service-role Edge Functions.';
COMMENT ON POLICY coin_transactions_select_own ON public.coin_transactions IS
  'Males read only their own ledger entries. Append-only via service role; never updated or deleted by app code.';

-- =============================================================================
-- credit_coins()  — the only authorised coin mutator
--
-- Atomically:
--   1. Locks public.males for the target user (FOR UPDATE).
--   2. Computes the new balance and rejects negatives.
--   3. Updates males.coin_balance.
--   4. Inserts a coin_transactions ledger row with computed balance_after.
--   5. Returns (transaction_id, previous_balance, new_balance).
--
-- p_amount semantics:
--   positive → credit  (purchase, chat_refund)
--   negative → debit   (chat_charge, razorpay_refund)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.credit_coins(
  p_male_id UUID,
  p_amount INTEGER,
  p_type coin_transaction_type,
  p_reference_id UUID DEFAULT NULL,
  p_description TEXT DEFAULT NULL
)
RETURNS TABLE (
  transaction_id UUID,
  previous_balance INTEGER,
  new_balance INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_current_balance INTEGER;
  v_new_balance INTEGER;
  v_transaction_id UUID;
BEGIN
  IF p_amount = 0 THEN
    RAISE EXCEPTION 'credit_coins called with amount = 0'
      USING ERRCODE = 'check_violation';
  END IF;

  -- Lock the row for the entire transaction.
  SELECT coin_balance INTO v_current_balance
  FROM public.males
  WHERE id = p_male_id
  FOR UPDATE;

  IF v_current_balance IS NULL THEN
    RAISE EXCEPTION 'Male user not found: %', p_male_id
      USING ERRCODE = 'no_data_found';
  END IF;

  v_new_balance := v_current_balance + p_amount;

  IF v_new_balance < 0 THEN
    RAISE EXCEPTION 'Insufficient coin balance: have=%, attempting change=%',
      v_current_balance, p_amount
      USING ERRCODE = 'check_violation';
  END IF;

  UPDATE public.males
  SET coin_balance = v_new_balance
  WHERE id = p_male_id;

  INSERT INTO public.coin_transactions
    (male_id, type, amount, balance_after, reference_id, description)
  VALUES
    (p_male_id, p_type, p_amount, v_new_balance, p_reference_id, p_description)
  RETURNING id INTO v_transaction_id;

  RETURN QUERY SELECT v_transaction_id, v_current_balance, v_new_balance;
END;
$$;

-- Lock down: only the service role may invoke. Edge Functions call this via
-- serviceClient(); user-facing code must never call it directly.
REVOKE EXECUTE ON FUNCTION public.credit_coins FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.credit_coins FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.credit_coins FROM anon;
GRANT EXECUTE ON FUNCTION public.credit_coins TO service_role;

COMMENT ON FUNCTION public.credit_coins IS
  'The only authorised coin mutator. Atomic FOR UPDATE balance change + append-only ledger insert. service_role only.';
