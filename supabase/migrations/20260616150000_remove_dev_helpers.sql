-- =============================================================================
-- Migration: Remove developer helper functions for production
-- =============================================================================

DROP FUNCTION IF EXISTS public.dev_list_females();
DROP FUNCTION IF EXISTS public.dev_toggle_verification(UUID);
