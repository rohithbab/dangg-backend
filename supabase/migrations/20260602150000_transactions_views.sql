-- =============================================================================
-- Migration: Transactions Views for Males and Females
--
-- This migration creates the following views:
--   * public.transactions — female-scoped transactions view mapping earnings/payouts/refunds
--   * public.male_transactions — male-scoped transactions view mapping coin transactions
--
-- RLS/Security:
--   Both views are filtered with `auth.uid() = ..._id` to enforce RLS at query time.
--   Select permissions are granted to the `authenticated` role.
--
-- Also standardizes female pricing by setting the default coin_price to 15
-- and updating all existing females' coin_price to 15.
-- =============================================================================

-- Create public.transactions view (for females)
CREATE OR REPLACE VIEW public.transactions AS
SELECT
  fe.id,
  fe.female_id,
  CASE
    WHEN fe.type = 'chat_earning' THEN 'earning'
    WHEN fe.type = 'payout' THEN 'payout'
    ELSE 'refund'
  END::text AS kind,
  CASE
    WHEN fe.type = 'chat_earning' THEN 'Chat Earnings'
    WHEN fe.type = 'payout' THEN 'UPI Payout'
    WHEN fe.type = 'chat_earning_reversed' THEN 'Refunded Earning'
    WHEN fe.type = 'payout_failed_reversal' THEN 'Payout Refunded'
    WHEN fe.type = 'admin_adjustment' THEN 'Admin Adjustment'
    ELSE 'Adjustment'
  END::text AS title,
  CASE
    WHEN fe.type = 'chat_earning' THEN COALESCE('Chat with ' || u.name, 'Chat Earnings')
    WHEN fe.type = 'payout' THEN
      CASE
        WHEN p.payout_method_snapshot->>'method' = 'upi' THEN 'Transferred to ' || (p.payout_method_snapshot->>'upi_id')
        WHEN p.payout_method_snapshot->>'method' = 'bank' THEN 'Transferred to A/C ending in ' || substring(p.payout_method_snapshot->>'account_number' from length(p.payout_method_snapshot->>'account_number')-3 for 4)
        ELSE COALESCE(fe.description, 'Withdrawal request')
      END
    ELSE COALESCE(fe.description, 'System transaction')
  END::text AS subtitle,
  ABS(fe.amount_coins) * 0.7 AS "amountInr",
  CASE
    WHEN fe.type = 'payout' THEN
      CASE
        WHEN p.status IN ('pending', 'approved') THEN 'processing'
        WHEN p.status = 'completed' THEN 'completed'
        ELSE 'failed'
      END
    ELSE 'completed'
  END::text AS status,
  fe.created_at AS "occurredAt",
  fe.created_at AS occurred_at
FROM public.female_earnings fe
LEFT JOIN public.chat_requests cr ON cr.id = fe.reference_id AND fe.type = 'chat_earning'
LEFT JOIN public.users u ON u.id = cr.male_id
LEFT JOIN public.payouts p ON p.id = fe.reference_id AND fe.type = 'payout'
WHERE fe.female_id = auth.uid();

GRANT SELECT ON public.transactions TO authenticated;

COMMENT ON VIEW public.transactions IS
  'Secure view for female users to query their transaction history. Restricts visibility using auth.uid().';

-- Create public.male_transactions view (for males)
CREATE OR REPLACE VIEW public.male_transactions AS
SELECT
  ct.id,
  ct.male_id,
  CASE
    WHEN ct.type = 'purchase' THEN 'purchase'
    WHEN ct.type = 'chat_charge' THEN 'chat'
    WHEN ct.type = 'chat_refund' THEN 'refund'
    WHEN ct.type = 'razorpay_refund' THEN 'refund'
    ELSE 'refund'
  END::text AS kind,
  CASE
    WHEN ct.type = 'purchase' THEN 'Coins Purchased'
    WHEN ct.type = 'chat_charge' THEN 'Chat Request'
    WHEN ct.type = 'chat_refund' THEN 'Refunded Coins'
    WHEN ct.type = 'razorpay_refund' THEN 'Razorpay Refund'
    WHEN ct.type = 'admin_adjustment' THEN 'Admin Adjustment'
    ELSE 'Wallet Transaction'
  END::text AS title,
  CASE
    WHEN ct.type = 'chat_charge' THEN COALESCE('Chat with ' || u.name, 'Chat request sent')
    WHEN ct.type = 'chat_refund' THEN COALESCE('Refunded coins (' || u.name || ')', 'Refunded coins')
    ELSE COALESCE(ct.description, 'Wallet transaction')
  END::text AS subtitle,
  ct.amount AS "coinDelta",
  'completed'::text AS status,
  ct.created_at AS "occurredAt",
  ct.created_at AS occurred_at
FROM public.coin_transactions ct
LEFT JOIN public.chat_requests cr ON cr.id = ct.reference_id AND ct.type IN ('chat_charge', 'chat_refund')
LEFT JOIN public.users u ON u.id = cr.female_id
WHERE ct.male_id = auth.uid();

GRANT SELECT ON public.male_transactions TO authenticated;

COMMENT ON VIEW public.male_transactions IS
  'Secure view for male users to query their transaction history. Restricts visibility using auth.uid().';

-- Standardize DB Female Pricing
ALTER TABLE public.females ALTER COLUMN coin_price SET DEFAULT 15;
UPDATE public.females SET coin_price = 15;
