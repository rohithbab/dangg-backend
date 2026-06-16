-- =============================================================================
-- Database trigger to insert notifications on female verification status change
-- =============================================================================

-- Create the trigger function
CREATE OR REPLACE FUNCTION public.handle_female_verification_status_update()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF OLD.verification_status IS DISTINCT FROM NEW.verification_status THEN
    IF NEW.verification_status = 'verified' THEN
      INSERT INTO public.notifications (recipient_id, type, title, body, data)
      VALUES (
        NEW.id,
        'verification_approved'::public.notification_type,
        'Verification approved',
        'Congratulations! Your profile has been verified. You can now start earning.',
        jsonb_build_object(
          'verification_status', 'verified'
        )
      );
    ELSIF NEW.verification_status = 'rejected' THEN
      INSERT INTO public.notifications (recipient_id, type, title, body, data)
      VALUES (
        NEW.id,
        'verification_rejected'::public.notification_type,
        'Verification rejected',
        COALESCE(NEW.verification_rejection_reason, 'Your verification photo did not meet requirements. Please submit a clear photo.'),
        jsonb_build_object(
          'verification_status', 'rejected',
          'reason', NEW.verification_rejection_reason
        )
      );
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Bind the trigger to the public.females table AFTER UPDATE
DROP TRIGGER IF EXISTS on_female_verification_updated ON public.females;
CREATE TRIGGER on_female_verification_updated
  AFTER UPDATE OF verification_status ON public.females
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_female_verification_status_update();

COMMENT ON FUNCTION public.handle_female_verification_status_update() IS
  'Trigger function that inserts a notification into public.notifications when a female user''s verification status transitions to verified or rejected.';
