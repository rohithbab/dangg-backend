-- Backfill profile_picture_url rows that were saved as bare R2 object keys
-- (e.g. "users/profile-images/<uid>/uuid.jpg") instead of full URLs.
-- This happened when R2_PUBLIC_BASE_URL was not set in the edge-function env,
-- causing media-sign to return publicUrl=null and the app to fall back to the
-- raw objectKey. FastImage receives a non-empty but non-loadable string,
-- skips the initials fallback, and renders nothing.
UPDATE public.users
SET profile_picture_url = 'https://media.dangg.app/' || profile_picture_url
WHERE profile_picture_url IS NOT NULL
  AND profile_picture_url NOT LIKE 'https://%'
  AND profile_picture_url NOT LIKE 'http://%';
