-- =============================================================================
-- Migration: Dev "VERIFY" toggle fully unblocks going online (dev mode only)
--
-- PROBLEM
--   In dev we mock the female OTP and skip the verification-photo capture AND
--   the bank/UPI ("account number") page. The Dev Verification FAB calls
--   `dev_toggle_verification`, which only flipped `verification_status`. But
--   `female-availability-toggle` ALSO requires a `payout_details` row, so a
--   dev female still hit "Add payment details to go online" and could never
--   appear on the male side.
--
-- FIX (dev-only helper — never on a real signup path)
--   When toggling a female TO 'verified', also provision a placeholder UPI
--   payout row if she has none, so the availability toggle's payout check
--   passes. When toggling AWAY from 'verified', force her offline so a now-
--   unverified row doesn't linger as "online" anywhere.
--
--   The placeholder is only INSERTed when missing — a tester who entered real
--   bank/UPI details keeps them; we never delete payout data here.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.dev_toggle_verification(p_female_id UUID)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_current public.verification_status;
  v_new public.verification_status;
BEGIN
  SELECT verification_status INTO v_current
  FROM public.females
  WHERE id = p_female_id;

  IF v_current = 'verified' THEN
    v_new := 'none'::public.verification_status;
  ELSE
    v_new := 'verified'::public.verification_status;
  END IF;

  UPDATE public.females
  SET verification_status = v_new,
      verification_submitted_at = CASE WHEN v_new = 'verified' THEN NOW() ELSE NULL END,
      verification_decided_at = CASE WHEN v_new = 'verified' THEN NOW() ELSE NULL END,
      -- A revoked female must not stay "online" / browseable.
      is_online = CASE WHEN v_new = 'verified' THEN is_online ELSE FALSE END
  WHERE id = p_female_id;

  -- Provision a placeholder payout method so the female can go online without
  -- the (dev-skipped) bank/UPI page. Inserted only if she has none.
  IF v_new = 'verified' THEN
    INSERT INTO public.payout_details (female_id, method, upi_id)
    VALUES (p_female_id, 'upi', 'devpayout@upi')
    ON CONFLICT (female_id) DO NOTHING;
  END IF;

  RETURN json_build_object(
    'id', p_female_id,
    'verification_status', v_new
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.dev_toggle_verification(UUID) TO authenticated;

COMMENT ON FUNCTION public.dev_toggle_verification(UUID) IS
  'DEV ONLY: Toggles a female verification status bypassing RLS, provisions a placeholder payout on verify, and forces offline on revoke so the availability toggle works end-to-end without the dev-skipped photo/bank pages.';
