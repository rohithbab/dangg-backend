-- Lists the caller's blocked users for the in-app "Blocked users" management
-- screen (where they unblock). SECURITY DEFINER so it can resolve the blocked
-- user's name/avatar regardless of the caller's RLS reach; only ever returns
-- rows the caller themselves created (blocker_id = auth.uid()).
CREATE OR REPLACE FUNCTION public.get_my_blocked_users()
RETURNS TABLE (
  id                  uuid,
  name                text,
  profile_picture_url text,
  blocked_at          timestamptz
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT u.id, u.name, u.profile_picture_url, b.created_at
  FROM public.user_blocks b
  JOIN public.users u ON u.id = b.blocked_id
  WHERE b.blocker_id = auth.uid()
  ORDER BY b.created_at DESC;
$$;

GRANT EXECUTE ON FUNCTION public.get_my_blocked_users() TO authenticated;
