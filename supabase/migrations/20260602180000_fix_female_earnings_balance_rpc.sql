-- =============================================================================
-- Migration: Fix female_earnings_balance() RPC Function
--
-- Replaces the incorrect column reference `amount_inr` in the payouts table
-- query with `payout_amount_paisa / 100.0`.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.female_earnings_balance()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_available_coins INT;
  v_pending_inr NUMERIC;
  v_month_coins INT;
  v_lifetime_coins INT;
BEGIN
  SELECT earnings_balance_coins INTO v_available_coins
  FROM public.females WHERE id = auth.uid();

  SELECT coalesce(sum(payout_amount_paisa) / 100.0, 0) INTO v_pending_inr
  FROM public.payouts WHERE female_id = auth.uid() AND status = 'pending';

  SELECT coalesce(sum(amount_coins), 0) INTO v_month_coins
  FROM public.female_earnings
  WHERE female_id = auth.uid() 
    AND type = 'chat_earning' 
    AND created_at >= date_trunc('month', now() at time zone 'utc');

  SELECT coalesce(sum(amount_coins), 0) INTO v_lifetime_coins
  FROM public.female_earnings
  WHERE female_id = auth.uid() 
    AND type = 'chat_earning';

  RETURN jsonb_build_object(
    'availableInr', coalesce(v_available_coins, 0) * 0.7,
    'pendingPayoutInr', v_pending_inr,
    'monthEarningsInr', v_month_coins * 0.7,
    'monthTrend', jsonb_build_object('kind', 'flat', 'label', '0% vs last month'),
    'lifetimeEarningsInr', v_lifetime_coins * 0.7
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.female_earnings_balance() TO authenticated;

COMMENT ON FUNCTION public.female_earnings_balance() IS
  'Returns the female earnings balances. Correctly computes pending payout in INR using payouts.payout_amount_paisa.';
