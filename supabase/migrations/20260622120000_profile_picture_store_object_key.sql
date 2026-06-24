-- =============================================================================
-- Switch profile_picture_url to store the R2 OBJECT KEY, not a public URL.
--
-- dangg-media is kept fully PRIVATE (no public bucket, no r2.dev). Images are
-- resolved to short-lived presigned GET URLs at display time via the
-- `media-sign-read` Edge Function. So profile_picture_url should hold a key like
--   users/profile-images/{uid}/{uuid}.jpg
-- (matching the media-sign upload key scheme), never an https://… link.
--
-- This strips any public-URL prefix from rows written before the switch:
--   • Supabase Storage public URL  (…/object/public/users/profile-images/…)
--   • any absolute URL             (r2.dev / custom domain, incl. optional
--                                    leading `dangg-media/` bucket segment)
-- Rows that are already keys or NULL are left untouched. Idempotent.
--
-- Gallery/chat image columns do NOT exist yet — when added (#3 chat media) they
-- store keys from the start. verification/photos and reports/evidence already
-- store keys and are intentionally NOT touched here.
-- =============================================================================

UPDATE public.users
SET profile_picture_url =
  CASE
    WHEN profile_picture_url ~ '/storage/v1/object/public/'
      THEN regexp_replace(profile_picture_url, '^.*/storage/v1/object/public/', '')
    WHEN profile_picture_url ~ '^https?://'
      THEN regexp_replace(profile_picture_url, '^https?://[^/]+/(dangg-media/)?', '')
    ELSE profile_picture_url
  END
WHERE profile_picture_url ~ '^https?://';
