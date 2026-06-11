-- =============================================================================
-- Migration: Developer verification helper functions (dev mode only)
--
-- Adds SECURITY DEFINER functions to query and update verification statuses,
-- bypassing RLS checks.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.dev_list_females()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN coalesce(
    (
      SELECT jsonb_agg(json_build_object(
        'id', u.id,
        'name', u.name,
        'phone', u.phone,
        'verification_status', f.verification_status
      ) ORDER BY u.name ASC)
      FROM public.users u
      JOIN public.females f ON f.id = u.id
    ),
    '[]'::jsonb
  );
END;
$$;

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
      verification_decided_at = CASE WHEN v_new = 'verified' THEN NOW() ELSE NULL END
  WHERE id = p_female_id;

  RETURN json_build_object(
    'id', p_female_id,
    'verification_status', v_new
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.dev_list_females() TO authenticated;
GRANT EXECUTE ON FUNCTION public.dev_toggle_verification(UUID) TO authenticated;

COMMENT ON FUNCTION public.dev_list_females() IS
  'DEV ONLY: Lists all female users and their verification status bypassing RLS.';
COMMENT ON FUNCTION public.dev_toggle_verification(UUID) IS
  'DEV ONLY: Toggles verification status of a female user bypassing RLS.';
