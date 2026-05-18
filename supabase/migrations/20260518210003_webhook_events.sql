-- =============================================================================
-- WEBHOOK_EVENTS  — idempotency tracker for incoming webhooks
--
-- Every webhook handler does the same dance:
--   1. Verify the signature.
--   2. INSERT a row here keyed by (provider, event_id).
--   3. If INSERT raises unique_violation → duplicate; respond 200 + skip.
--   4. Otherwise, process the event, then UPDATE processed_at.
--   5. On processing failure, UPDATE processing_error and return non-2xx so
--      the provider retries.
--
-- Service-role only — Edge Functions write to this table; users never see it.
-- =============================================================================

CREATE TABLE public.webhook_events (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  provider TEXT NOT NULL CHECK (provider IN ('razorpay')),
  event_id TEXT NOT NULL,
  event_type TEXT NOT NULL,
  payload JSONB NOT NULL,
  received_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  processed_at TIMESTAMPTZ,
  processing_error TEXT,

  -- The idempotency key. A provider must never deliver the same event_id
  -- twice; if it does, the UNIQUE violation is caught by the webhook
  -- handler and the duplicate is acknowledged with 200 + no-op.
  CONSTRAINT webhook_events_unique_provider_event UNIQUE (provider, event_id)
);

CREATE INDEX webhook_events_provider_received_idx
  ON public.webhook_events(provider, received_at DESC);
CREATE INDEX webhook_events_unprocessed_idx
  ON public.webhook_events(received_at)
  WHERE processed_at IS NULL;

-- Service role only. RLS is enabled (default deny) with zero policies.
ALTER TABLE public.webhook_events ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE public.webhook_events IS
  'Idempotency tracker for inbound webhooks. INSERT (provider, event_id) before processing; UNIQUE prevents reprocessing.';
COMMENT ON COLUMN public.webhook_events.processing_error IS
  'Set when processing fails. The row stays so admin can investigate / retry.';
COMMENT ON COLUMN public.webhook_events.processed_at IS
  'Null until the handler completes successfully. Combined with the unprocessed index, supports a reconciliation cron job.';
