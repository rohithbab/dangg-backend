-- =============================================================================
-- Migration: Get Female Verification Status RPC
--
-- Adds a SECURITY DEFINER function to check the verification status of a female
-- user by phone number. Since this is queried prior to password login, the
-- caller is anonymous and cannot query the users/females tables directly due to
-- RLS. This function runs as the owner (bypassing RLS) and is granted to anon.
-- Returns verification status, name, and profile picture url as JSONB.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.get_female_verification_status(p_phone text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status text;
  v_name text;
  v_avatar text;
  v_clean_phone text;
BEGIN
  -- Normalize phone: strip leading '+' if present
  v_clean_phone := regexp_replace(p_phone, '^\+', '');

  SELECT f.verification_status::text, u.name, u.profile_picture_url 
  INTO v_status, v_name, v_avatar
  FROM public.females f
  JOIN public.users u ON u.id = f.id
  WHERE u.phone = v_clean_phone;

  RETURN jsonb_build_object(
    'verification_status', coalesce(v_status, 'none'),
    'name', v_name,
    'profile_picture_url', v_avatar
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_female_verification_status(text) TO anon, authenticated;

COMMENT ON FUNCTION public.get_female_verification_status(text) IS
  'Checks the verification status, name, and profile picture of a female user by phone number.';
