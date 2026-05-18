-- =============================================================================
-- CHAT REQUESTS — Phase-1 state machine
--
--      send             accept        ──► accepted   (credit female earnings)
--   ────────► pending ──┤  decline    ──► declined   (refund male)
--                       │  cancel     ──► cancelled  (refund male)
--                       │  expires_at ──► expired    (refund male, via pg_cron)
--                       │
--                       └ All terminal states are final — no further transitions.
--
-- Hard invariants enforced at the DB layer:
--   * Male cannot send to himself — CHECK (male_id <> female_id).
--   * A male can only have ONE pending request at a time — partial UNIQUE
--     index on (male_id) WHERE status = 'pending'.
--   * Terminal rows must carry the right ledger linkage:
--       accepted          → earning_id NOT NULL
--       declined/cancelled/expired → refund_transaction_id NOT NULL
--   * Pending rows must NOT have responded_at / response_reason set.
--
-- All writes flow through Edge Functions running as service_role. There are
-- no INSERT / UPDATE / DELETE policies — the SELECT policies are the only
-- way authenticated users touch this table.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- chat_request_status enum
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'chat_request_status') THEN
    CREATE TYPE public.chat_request_status AS ENUM (
      'pending',
      'accepted',
      'declined',
      'cancelled',
      'expired'
    );
  END IF;
END$$;

COMMENT ON TYPE public.chat_request_status IS
  'State machine for chat_requests. pending is the only non-terminal state; the four terminal states are final and disambiguate who triggered the transition (female: accepted/declined; male: cancelled; system: expired).';

-- ---------------------------------------------------------------------------
-- chat_requests table
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.chat_requests (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),

  male_id   UUID NOT NULL REFERENCES public.users (id) ON DELETE RESTRICT,
  female_id UUID NOT NULL REFERENCES public.users (id) ON DELETE RESTRICT,

  -- Cost snapshotted at send time — the female may change her coin_price
  -- after the request is sent, but the request honours the original price.
  chat_cost_coins INTEGER NOT NULL CHECK (chat_cost_coins > 0),

  status public.chat_request_status NOT NULL DEFAULT 'pending',

  sent_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at   TIMESTAMPTZ NOT NULL,
  responded_at TIMESTAMPTZ,
  response_reason TEXT,

  -- Ledger linkage. Populated as transitions execute.
  --   charge_transaction_id  — initial debit on send (coin_transactions.id)
  --   refund_transaction_id  — refund on decline/cancel/expire (coin_transactions.id)
  --   earning_id             — credit to female on accept (female_earnings.id)
  charge_transaction_id UUID,
  refund_transaction_id UUID,
  earning_id            UUID,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- Defense in depth: prevent a male from chatting himself.
  CONSTRAINT chat_requests_no_self CHECK (male_id <> female_id),

  -- Pending rows must not have responded_at / response_reason.
  -- Terminal rows must have both.
  CONSTRAINT chat_requests_pending_has_no_response CHECK (
    status <> 'pending'
    OR (responded_at IS NULL AND response_reason IS NULL)
  ),
  CONSTRAINT chat_requests_terminal_has_responded CHECK (
    status = 'pending'
    OR (responded_at IS NOT NULL AND response_reason IS NOT NULL)
  ),

  -- Terminal rows must reference the right ledger entry.
  CONSTRAINT chat_requests_accepted_has_earning CHECK (
    status <> 'accepted' OR earning_id IS NOT NULL
  ),
  CONSTRAINT chat_requests_refunded_has_refund CHECK (
    status NOT IN ('declined', 'cancelled', 'expired')
    OR refund_transaction_id IS NOT NULL
  ),

  -- expires_at must be strictly after sent_at.
  CONSTRAINT chat_requests_expires_after_sent CHECK (expires_at > sent_at)
);

COMMENT ON TABLE public.chat_requests IS
  'Chat-request state machine. One row per send attempt. Terminal states are final; coin movements are linked via charge_transaction_id / refund_transaction_id / earning_id.';
COMMENT ON COLUMN public.chat_requests.chat_cost_coins IS
  'Snapshot of females.coin_price at send time. Future price changes do not affect requests already in flight.';
COMMENT ON COLUMN public.chat_requests.expires_at IS
  'Wall-clock time at which a pending request flips to expired. Set to sent_at + 120s by the send Edge Function; enforced by pg_cron.';
COMMENT ON COLUMN public.chat_requests.charge_transaction_id IS
  'coin_transactions.id of the initial chat_charge debit. Populated on send.';
COMMENT ON COLUMN public.chat_requests.refund_transaction_id IS
  'coin_transactions.id of the chat_refund credit. Populated on decline / cancel / expire.';
COMMENT ON COLUMN public.chat_requests.earning_id IS
  'female_earnings.id of the chat_earning credit. Populated on accept only.';

-- ---------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------

-- Hard guarantee: one pending per male. The send Edge Function pre-checks
-- this for a friendly error, but this partial unique index is the
-- authoritative enforcer (also catches concurrent racing inserts).
CREATE UNIQUE INDEX IF NOT EXISTS chat_requests_one_pending_per_male_idx
  ON public.chat_requests (male_id)
  WHERE status = 'pending';

COMMENT ON INDEX public.chat_requests_one_pending_per_male_idx IS
  'A male can only have ONE pending chat request at a time. Partial unique index over male_id where status=pending.';

-- Female fetching her pending requests (incoming-request popup + Phase 2 queue).
CREATE INDEX IF NOT EXISTS chat_requests_female_pending_idx
  ON public.chat_requests (female_id, sent_at DESC)
  WHERE status = 'pending';

-- Male history (request list / wallet sidebar).
CREATE INDEX IF NOT EXISTS chat_requests_male_created_at_idx
  ON public.chat_requests (male_id, created_at DESC);

-- Female history (earnings dashboard).
CREATE INDEX IF NOT EXISTS chat_requests_female_created_at_idx
  ON public.chat_requests (female_id, created_at DESC);

-- Cron expiry: B-tree on expires_at filtered to pending — the only rows
-- the cron ever cares about.
CREATE INDEX IF NOT EXISTS chat_requests_pending_expiry_idx
  ON public.chat_requests (expires_at)
  WHERE status = 'pending';

-- ---------------------------------------------------------------------------
-- updated_at trigger (set_updated_at lives in the init migration).
-- ---------------------------------------------------------------------------
DROP TRIGGER IF EXISTS chat_requests_set_updated_at ON public.chat_requests;
CREATE TRIGGER chat_requests_set_updated_at
  BEFORE UPDATE ON public.chat_requests
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- ---------------------------------------------------------------------------
-- RLS
--
-- Read access: male sees rows where male_id = self; female sees rows where
-- female_id = self. No other reader.
--
-- Write access: NONE for authenticated. All inserts / updates flow through
-- the Edge Functions (service_role), which run the ledger calls under
-- credit_coins() / credit_female_earnings() locks.
-- ---------------------------------------------------------------------------
ALTER TABLE public.chat_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS chat_requests_select_male_own ON public.chat_requests;
CREATE POLICY chat_requests_select_male_own
  ON public.chat_requests
  FOR SELECT
  USING (auth.uid() = male_id);

DROP POLICY IF EXISTS chat_requests_select_female_own ON public.chat_requests;
CREATE POLICY chat_requests_select_female_own
  ON public.chat_requests
  FOR SELECT
  USING (auth.uid() = female_id);

COMMENT ON POLICY chat_requests_select_male_own   ON public.chat_requests IS
  'Male reads chat_requests where they are the sender. No update/delete — all writes go through Edge Functions under service_role.';
COMMENT ON POLICY chat_requests_select_female_own ON public.chat_requests IS
  'Female reads chat_requests addressed to her. No update/delete — all writes go through Edge Functions under service_role.';

-- ---------------------------------------------------------------------------
-- Realtime publication
--
-- Both sides need live updates: male watches their pending request flip,
-- female receives incoming-request popups. RLS filters per-subscriber.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'chat_requests'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.chat_requests;
  END IF;
END$$;
